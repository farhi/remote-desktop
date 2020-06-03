# This is a CGI script to provide a remote desktop service.
# 
# Warning: this CGI must be called with the POST method, as emails/passwd
#   may be sent. These must not appear in the URL (get method).
#
# Installation
# ============
#
# Steps
# =====
# - service configuration block (life-time, limits)
# - check of input variables (from the form)
# - check user credentials (email or LDAP)
# - clean up "old" instances if needed
# - create snapshot (ISO, qcow2, vdi, vmdk) 
# - launch qemu and tight to novnc
# - display 'result' message, send token via email or displayed
# - write lock file
# - wait for qemu/novnc to end
# - clean-up 
#

# Python CGI example:
# - https://www.tutorialspoint.com/python/python_cgi_programming.htm

# Import basic stuff: OS to e.g. test for files, ...
import os
import time
import glob
import pickle
import tempfile
import shutil
import atexit

# Process management and info on the system
import psutil
import signal
import subprocess
import shlex
import socket  

# Import modules for CGI handling 
import cgi, cgitb 


# ==============================================================================
#                            The MAIN is at the end
#
#                      Configure 'session_get_config' below !
#
#                 All called functions are in the calling order.
# ==============================================================================

# NOTE: This is where you can tune the default service configuration.
#       Adapt the path, and default VM specifications.

def service_get_config():
  """Get service and system configuration.
  
  Returns
  -------
  config : Dict
  """
  
  c = {}; # we store all in a Dict (config)
  
  # base directory were all resides
  c['service']                  = "/var/www/html/desktop/"

  # where to store ISO, QCOW2, VMDK and VDI files.
  c['machines']                 = os.path.join(c['service'], "machines")

  # where to create snapshots from above VM's.
  c['snapshots']                = os.path.join(c['service'], "snapshots")

  # where is noVNC ? Can run with Python3 OK.
  c['novnc']                    = os.path.join(c['service'], "novnc")

  # life time in [s]. Kill instance when above. One day is 86400.
  c['snapshot_lifetime']        = 86400 

  # default nb of CPU per instance.
  c['snapshot_alloc_cpu']       = 1

  # default nb of RAM per instance (in MB).
  c['snapshot_alloc_mem']       = 4096

  # default size of disk per instance (in GB). Only for ISO machines.
  c['snapshot_alloc_disk']      = 10
  
  # default machine to run
  c['machine']                  = 'dsl.iso'
  
  # QEMU executable. Adapt to the architecture you run on.
  c['qemu_exec']                = "qemu-system-x86_64"

  # label used for naming temporary files.
  c['service_name']             = "desktop" 

  # max amount [0-1] of CPU load. Deny service when above.
  c['service_max_load']         = 0.8   

  # max number of active sessions. Deny service when above.
  c['service_max_instance_nb']  = 10    

  # allow re-entrant sessions. Safer with single-shot, but limited in use.
  c['service_allow_persistent'] = False  

  # will allow anybody to use service (no check for ID - only on secured network).
  c['service_allow_anonymous']  = True  

  # will allow users with emails to use service.
  c['service_allow_emailed']    = True  

  # will allow users from LDAP to use service.
  c['service_allow_ldap']       = True  
  
  # must use token to connect (highly recommended)
  c['service_use_vnc_token']    = True
  
  # the name of the SMTP server, and optional port. None will disable.
  c['smtp_server']              = "smtp.synchrotron-soleil.fr"
  c['smtp_port']                = "" # can be e.g. 465, 587, or left blank
  # the email address of the sender of the messages on the SMTP server. 
  #   None will disable
  c['email_from']               = "luke.skywalker@synchrotron-soleil.eu"
  
  # get info about the running host
  c['hostname']                 = socket.getfqdn()
  c['cpu_count']                = os.cpu_count()  # incl. threads
  c['mem_load']                 = psutil.virtual_memory().percent
  
  # cpu load must be      < c['service_max_load']
  c['cpu_load']                 = psutil.cpu_percent()/100 # current load
  
  # available cpu must be > c['snapshot_alloc_cpu']
  c['cpu_avail']                = (1-psutil.cpu_percent()/100)*os.cpu_count()
  
  # available memory must be > c['snapshot_alloc_mem']*1024**2
  c['mem_avail']                = psutil.virtual_memory().available
  
  # available disk must be > c['snapshot_alloc_disk']*1024**3
  c['disk_avail']               = psutil.disk_usage(c['service']).free
  
  # Check for service availability (dir, files, machine load)
  if not os.path.isdir(c['service']):
    raise FileNotFoundError('Invalid Service directory: %s' % c['service'])
  
  if not os.path.isdir(c['machines']):
    raise FileNotFoundError('Invalid Machines directory: %s' % c['machines'])
    
  if not os.path.isdir(c['snapshots']):
    raise FileNotFoundError('Invalid Snapshots directory: %s' % c['snapshots'])
    
  if not os.path.isdir(c['novnc']):
    raise FileNotFoundError('Invalid noVNC directory: %s' % c['novnc'])
    
  if not os.path.exists(os.path.join(c['novnc'],"utils","websockify","run")):
     raise FileNotFoundError('Can not find noVNC executable: %s' \
       % os.path.join(c['novnc'],"utils","websockify","run"))
  
  if c['cpu_load'] > c['service_max_load']:
    raise OverflowError('Host load is already too high: %f' % c['cpu_load'])
    
  # logging
  print("[%s] Current configuration:" % time.asctime(time.localtime()))
  print(*c.items(), sep='\n')
  
  return c # config
  
  # end: service_get_config

# ------------------------------------------------------------------------------  

def service_housekeeping(c):
  """ We look for all registered instances. 
  Kill those that have exceeded their life-ti
  
  Parameters
  ----------
  c : config Dict
  """
  
  # Get all active session pickles.
  active = glob.glob(os.path.join(c['snapshots'], c['service_name'] + '_*.pkl'))
  
  # get all pickles in "snapshots". Name is config['service_name'] + '_' ...
  # - Get their creation ti
  # - Compare with now+lifeti
  # - when above, import pickle and call session_stop
  
  c['used_index'] = []
  
  for session_pkl in active:
    date_modified =  os.path.getmtime(session_pkl)
    now           = timktime(datetinow().timetuple())
    
    with open(session_pkl, "rb") as session_file:
      # when file is older than life time, stop session
      session = pickle.load(session_file) # auto close
      
      if now - date_modified > c['snapshot_lifetime']:
        session_stop(session)            # kill and clean files
      elif 'snapshot_index' in session: # get current session port
        c['used_index'].append(session['snapshot_index'])
  
  # Check for nb of remaining sessions.
  active = glob.glob(os.path.join(c['snapshots'], c['service_name'] + '_*.pkl'))
  if len(active) > c['service_max_instance_nb']:
    raise SystemError('Too many active sessions: %s' % len(active))
    
  # end: service_housekeeping

# ------------------------------------------------------------------------------

def session_init(c):
  """Get user input from the FORM into 'session' variables
  
  Parameters
  ----------
  c : config Dict
  
  Returns
  -------
  s : session Dict
  """
  
  s = {}  # a Dict (session)
  
  # Generate unique ID (for storing session data)
  s['snapshot_name'] = \
    c['service_name'] + '_' + next(tempfile._get_candidate_names())
    
  # Generate unique token for VNC
  if c['service_use_vnc_token']:
    s['vnc_token'] = next(tempfile._get_candidate_names())
    
  # Init default session parameters (from service defaults)
  s['snapshot_lifetime']        = c['snapshot_lifetime'] 
  s['snapshot_alloc_cpu']       = c['snapshot_alloc_cpu']
  s['snapshot_alloc_mem']       = c['snapshot_alloc_mem']
  s['snapshot_alloc_disk']      = c['snapshot_alloc_disk']
  s['machine']                  = c['machine']
  s['snapshot_persistent']      = c['service_allow_persistent']
  
  s['session_start'] = time.asctime(time.localtime())
  
  # Get values from the FORM
  use_form = False
  if use_form:
    # Create instance of FieldStorage to get variables from the FORM
    #   each named field is retrieved with form.getvalue('name')
    form = cgi.FieldStorage() 
    s['machine']                  = form.getvalue('machine')
    s['snapshot_alloc_cpu']       = form.getvalue('cpu')
    s['snapshot_alloc_mem']       = form.getvalue('memory')
    s['snapshot_alloc_disk']      = form.getvalue('disk') # only for ISO
    
  try:
    s['remote_host'] = cgi.escape(os.environ["REMOTE_ADDR"])
  except:
    s['remote_host'] = "127.0.0.1"
  if s['remote_host'] == "::1":
    s['remote_host'] = "127.0.0.1"

  # Get a session index, used for VNC port/ip
  if len(c['used_index']):
    # search a free slot in used session indices
    s['snapshot_index'] = max(c['used_index'])+1 # default
    for x in range(max(c['used_index'])):         # starting from 0
      if x in c['used_index']:
        continue
      else:
        s['snapshot_index'] = x
        break
  else:
    s['snapshot_index'] = 0
    
  s['snapshot_pickle'] = os.path.join(c['snapshots'], \
    s['snapshot_name'] + '.pkl')
  
  # set VNC IP and PORT
  s['qemuvnc_ip'] = "127.0.0.%i" % (s['snapshot_index']+1)
  # find a port which is not used. 1st is 6080 (noVNC)
  s['novnc_port'] = None
  with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    for x in range(6080, 6080+c['service_max_instance_nb']):
      try:
        sock.bind((s['qemuvnc_ip'], x))
        s['novnc_port'] = x
        break
      except socket.error as e:
        # port in use. Try next one.
        s['novnc_port'] = None
        
  if s['novnc_port'] is None:
    raise OverflowError('Could not find a free port for QEMU VNC.')

  # Perform checks
  if not os.path.exists(os.path.join(c['machines'], s['machine'])):
    raise FileNotFoundError('Virtual Machine does not exist.')
  
  # available cpu must be > c['snapshot_alloc_cpu']
  if c['cpu_avail'] < s['snapshot_alloc_cpu']:
    raise OverflowError('Not enough free CPU to run: %f' % c['cpu_avail'])
  
  # available memory must be > c['snapshot_alloc_mem']*1024**2
  if c['mem_avail'] < s['snapshot_alloc_mem']*(1024**2):
    raise OverflowError('Not enough free memory to run.')
  
  # available disk must be > c['snapshot_alloc_disk']*1024**3
  if c['disk_avail'] < s['snapshot_alloc_disk']*(1024**3):
    raise OverflowError('Not enough free disk to run: %f' % c['disk_avail'])
    
  if not c['service_allow_persistent']:
    s['snapshot_persistent'] = False

  # logging
  print("[%s] Init session %s to run %s" \
    % (s['session_start'],s['snapshot_name'], s['machine']))
  print("[%s] Index [%i] VNC %s:%i" \
    % (s['session_start'],s['snapshot_index'],s['qemuvnc_ip'],s['novnc_port']) )
    
  return s # session
  
  # end: session_init

# ------------------------------------------------------------------------------

def session_check_credentials(c, s):
  """Check user credentials and add a unique token to session.
  
  Parameters
  ----------
  c : config Dict
  s : session Dict
  
  """

  # user is 'anonymous': display the token in the 'result' page.

  # user is identified with email: we shall send the token via email.

  # user is registered via LDAP: we get its email, and shall send the token there.
  
  # user if admin account: can stop sessions, display history

# ------------------------------------------------------------------------------

def session_create_snapshot(c, s):
  """Create a snapshot from the VM (call 'qemu-img create'). 
  Add snapshot name to session.
  Supported machine formats: ISO, QCOW, QCOW2, VDI, VMDK, RAW/IMG
  
  Parameters
  ----------
  c : config Dict
  s : session Dict
  """

  # full path to instance directory
  s['snapshot_dir'] = \
      os.path.join(c['snapshots'], s['snapshot_name'])
      
  os.mkdir(s['snapshot_dir']) # raise FileExistsError when already there.
      
  # full path to snapshot qemu file
  s['snapshot'] = \
    os.path.join(s['snapshot_dir'], c['service_name']+'.qcow2')

  if s['machine'].lower().endswith('.iso'):  # ISO: raw empty disk
    cmd = "qemu-img create -f qcow2 %s %fG" \
      %(s['snapshot'], s['snapshot_alloc_disk'])

  else: # (RAW/IMG,QCOW,QCOW2,VDI,VMDK) snapshot from machine
    cmd = "qemu-img create -b %s -f qcow2 %s" \
      % (s['snapshot'], os.path.join(c['machines'], s['machine']))
  
  os.system(cmd); # execute command. We could use subprocess.run instead.
  
  # check that the snapshot file now exists
  if not os.path.exists(s['snapshot']):
    raise FileNotFoundError('Snapshot file could not be created: %s' \
      % s['snapshot'])
      
  # logging
  print("[%s] Created snapshot %s from %s" \
    % (s['session_start'],s['snapshot'], s['machine']))
  
# ------------------------------------------------------------------------------

def session_start_snapshot(c, s):
  """Change VNC token and launch snapshot (call 'qemu-system-x86_64')
  Add snapshot PID to session.
  Supported machine formats: ISO, QCOW, QCOW2, VDI, VMDK, RAW/IMG
  
  Parameters
  ----------
  c : config Dict
  s : session Dict
  """
  # common options for QEMU
  cmd = c['qemu_exec']                              + \
    " -hda "  + s['snapshot']                       + \
    " -smp "  + str(s['snapshot_alloc_cpu'])        + \
    " -m "    + str(s['snapshot_alloc_mem'])        + \
    " -machine pc,accel=kvm -enable-kvm "           + \
    " -net user -net nic,model=ne2k_pci -cpu host " + \
    " -vga qxl"
  
  if s['machine'].lower().endswith('.iso'):     # ISO
    cmd += " -boot d" + \
      " -cdrom " + os.path.join(c['machines'], s['machine'])
  else:                                       # (QCOW,QCOW2,VDI,VMDK,RAW/IMG)
    cmd += " -boot c "

  # connect to QEMU VNC (127.0.0.index:5900+index)
  cmd += " -vnc %s:1" % s['qemuvnc_ip']
  
  # concatenate VNC token and change it in the QEMU monitor
  if c['service_use_vnc_token'] and 'vnc_token' in s:
    s['snapshot_token_file'] = os.path.join(s['snapshot_dir'],"token")
    with open(s['snapshot_token_file'], "w") as f:
      f.write("change vnc password\n%s\n" % s['vnc_token']) # auto close

    # redirect 'token' to STDIN to set the VNC password
    #   stdout=/dev/null to avoid interference with stdin in qemu monitor
    cmd   += ",password -monitor stdio"
    with open(s['snapshot_token_file'],"r") as stdin:
      # launch cmd in background. Must retrieve PIDs (as group)
      proc = subprocess.Popen(shlex.split(cmd), stdin=stdin, \
          stdout=subprocess.DEVNULL)
      s['snapshot_qemu_pid'] = proc.pid
      time.sleep(5)
      # auto close token file
      
    # remove token file
    os.unlink(s['snapshot_token_file']) # or raise OSError/FileNotFoundError
  
  else: 
    # launch cmd in background. Must retrieve PIDs (as group)
    proc = subprocess.Popen(shlex.split(cmd))
    s['snapshot_qemu_pid'] = proc.pid # store the PID which can be pickled
    time.sleep(5)
    
# ------------------------------------------------------------------------------

def session_start_novnc(c, s):
  """Launch noVNC (call 'novnc/utils/websockify/run').
  
  Parameters
  ----------
  c : config Dict
  s : session Dict
  """
  
  cmd= os.path.join(c['novnc'],"utils","websockify","run")  +\
    " --web " + c['novnc']                                  +\
    " "       + str(s['novnc_port'])                        +\
    " "       + str(s['qemuvnc_ip']) + ":5901"          
    
  if not s['snapshot_persistent']:
    cmd += " --run-once"

  # launch cmd in background. Must retrieve PIDs (as group)
  proc = subprocess.Popen(shlex.split(cmd))
  s['snapshot_novnc_pid'] = proc.pid # store the PID which can be pickled
  
  # store URL's to access the service
  s['url1'] = "http://%s:%i/vnc.html?host=%s&port=%s" \
    % (c['hostname'],s['novnc_port'], c['hostname'],s['novnc_port'])
  s['url2'] = "http://%s:%s/vnc.html?host=%s&port=%s" \
    % (s['remote_host'], s['novnc_port'], s['remote_host'], s['novnc_port'])
  
# ------------------------------------------------------------------------------

def session_display(s):
  """Save session info. Send message to the user via email, and display it.
  
  Parameters
  ----------
  c : config Dict
  s : session Dict
  """
  
  # we store all children processes
  pids      = get_child_processes(s['snapshot_qemu_pid'] )
  pids.append(get_child_processes(s['snapshot_novnc_pid']))
  
  def flatten(li):
    return sum(([x] if not isinstance(x, list) else flatten(x)
                for x in li), [])
                
  # make it a flat list
  s['pids'] = flatten(pids)
  
  # save session
  with open(s['snapshot_pickle'],'wb') as f:
    pickle.dump(s,f)
  
  # logging
  print("[%s] Current session:" % time.asctime(time.localtime()))
  print(*s.items(), sep='\n')
  
  # - display 'result' message, send token via email or displayed
  print("  URL:   %s" % s['url1'])
  print("  URL:   %s" % s['url2'])
  if 'vnc_token' in s:
    print("  Token: %s" %s['vnc_token'])
  
  
# ------------------------------------------------------------------------------

def session_wait(s):
  """Wait for noVNC (not persistent) or QEMU (persistent) to end.
  
  Parameters
  ----------
  c : config Dict
  s : session Dict
  """
  
  if s['snapshot_persistent']:
    os.waitpid(s['snapshot_qemu_pid'], 0)
  else:
    os.waitpid(s['snapshot_novnc_pid'], 0)
  
# ------------------------------------------------------------------------------
def get_child_processes(parent_pid):
  parent = psutil.Process(parent_pid)
  children = parent.children(recursive=True)
  children.append(parent)
        
  pid = [];
  for p in children:
    pid.append(p.pid)
    
  return pid

def session_stop(s):
  """Kill any remaining processes (session), and delete remaining temporary 
  files.
  
  Parameters
  ----------
  s : session Dict
  """
  
  # logging
  print("[%s] Exiting session %s running %s" \
    % (s['session_start'],s['snapshot_name'], s['machine']))
    
  # remove file/dir (as we be kill ourselfves further)
  if 'snapshot_dir' in s and os.path.isdir(s['snapshot_dir']):
      print("[%s] Delete %s" \
        % (time.asctime(time.localtime()), s['snapshot_dir']))
      shutil.rmtree(s['snapshot_dir'], ignore_errors=True)
  
  if 'snapshot_pickle' in s and os.path.exists(s['snapshot_pickle']):
      print("[%s] Delete %s" \
        % (time.asctime(time.localtime()), s['snapshot_pickle']))
      os.unlink(s['snapshot_pickle'])
  
  # kill all child processes
  if 'pids' in s:
    for sig in [signal.SIGTERM, signal.SIGKILL]:
      for pid in s['pids']:
        # send signal when still active (but not ourselves)
        if psutil.pid_exists(pid) and pid != os.getpid():
          print("[%s] Kill %i" \
            % (time.asctime(time.localtime()), pid))
          os.killpg(os.getpgid(pid), sig)
          time.sleep(1)

# ==============================================================================
#
#                                  MAIN
#
# ==============================================================================

# this is where the job is done, calling above functions

if __name__ == "__main__":
  
  # Get service configuration
  config = service_get_config()
  
  # House-keeping: clean-up outdated sessions
  service_housekeeping(config)
  
  # Get session parameters (from the FORM)
  session = session_init(config)
  
  # once created, register for cleanup in case if premature exit
  atexit.register(session_stop, session)
  
  # Check user credentials and add a unique token to session
  session_check_credentials(config, session)
  
  # Create a snapshot from the VM (call 'qemu-img create'). 
  #   Add snapshot name to session.
  session_create_snapshot(config, session)
  
  # Change VNC token and launch snapshot (call 'qemu-system-x86_64')
  #   Add snapshot PID to session.
  session_start_snapshot(config, session)
  
  # Launch noVNC (call 'novnc/utils/websockify/run')
  session_start_novnc(config, session)
  
  # Send message to the user via email, and display it.
  #   Save session info.
  session_display(session)
  
  # Wait for noVNC (not persistent) or QEMU (persistent) to end
  session_wait(session)
  
  # kill all PID's and delete files/directories
  session_stop(session)
  
