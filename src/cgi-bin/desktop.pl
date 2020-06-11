#!/usr/bin/perl -w

# This script is triggered by a FORM or runs as a script.
# to test this script, launch from the project root level something like:
#
#   cd remote-desktop
#   perl src/cgi-bin/desktop.pl --dir_service=src/html/desktop \
#     --dir_html=src/html --dir_snapshots=/tmp
#
# Then follow printed instructions in the terminal:
# open a browser at something like:
# - http://localhost:38443/vnc.html?host=localhost&port=38443
#
# The script is effectively used in two steps (when executed as a CGI):
# - The HTML FORM launches the script as a CGI which starts the session.
#   QEMU and VNC are initiated, the message is displayed, but does not wait for
#   the end of the session. Instead, the same script is also launched in 
#   background as:
#     desktop.pl --session_watch=$json_session_file
# - The script launched with --session_watch monitors the specified session and 
#   clean all when done. This allows not to block the dynamic HTML rendering.
#
# A running session with an attached JSON file can be stopped with:
#
#   perl desktop.pl --session_stop=/path/to/json
#
# Requirements
# ============
# sudo apt install apache2 libapache2-mod-perl2
# sudo apt install qemu-kvm bridge-utils qemu iptables dnsmasq
#
# sudo apt install libsys-cpu-perl libsys-cpuload-perl libsys-meminfo-perl
#
# sudo apt install libcgi-pm-perl            
# sudo apt install libnet-dns-perl           libproc-background-perl 
# sudo apt install libproc-processtable-perl libemail-valid-perl
#
# sudo apt install libnet-smtps-perl libmail-imapclient-perl 
# sudo apt install libnet-ldap-perl  libemail-valid-perl
#
# (c) 2020 Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.



# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

# TODO:
# - User credentials
# - email
# - monitoring

# dependencies -----------------------------------------------------------------

use strict;

use CGI;                # use CGI.pm
use File::Temp      qw/ tempdir tempfile /;
use File::Path      qw/ rmtree  /;
use File::Basename  qw(fileparse);
use List::MoreUtils qw(uniq); # liblist-moreutils-perl
use Sys::CPU;           # libsys-cpu-perl           for CPU::cpu_count
use Sys::CpuLoad;       # libsys-cpuload-perl       for CpuLoad::load
use JSON;               # libjson-perl              for JSON
use IO::Socket::INET;
use IO::Socket::IP;
use Sys::MemInfo qw(freemem);
use Proc::Background;   # libproc-background-perl   for Background->new
use Proc::ProcessTable; # libproc-processtable-perl
use Proc::Killfam;      # libproc-processtable-perl for killfam (kill pid and children)

use Net::SMTPS;         # libnet-smtps-perl         for smtp user check and emailing
use Mail::IMAPClient;   # libmail-imapclient-perl   for imap user check
use Net::LDAP;          # libnet-ldap-perl          for ldap user check
use Email::Valid;       # libemail-valid-perl

# ------------------------------------------------------------------------------
# service configuration: tune for your needs
# ------------------------------------------------------------------------------

# NOTE: This is where you can tune the default service configuration.
#       Adapt the path, and default VM specifications.

# we use a Hash to store the configuration. This is simpler to pass to functions.
my %config;

$config{version}                  = "20.06";  # yesr.month

# WHERE THINGS ARE -------------------------------------------------------------

# name of service, used as directory and e.g. http://127.0.0.1/desktop
$config{service}                  = "desktop";              

# full path to Apache HTML root
#   Apache default on Debian is /var/www/html
$config{dir_html}                 = "/var/www/html"   ;    

# full path to root of the service area
#   e.g. /var/www/html/desktop
$config{dir_service}              = "$config{dir_html}/$config{service}";

# full path to machines (ISO,VM)
$config{dir_machines}             = "$config{dir_service}/machines";

# full path to snapshots and temporary files
$config{dir_snapshots}            = "$config{dir_service}/snapshots";

# full path to snapshot config/lock files. Must NOT be accessible from http://
#   e.g. /tmp to store "desktop_XXXXXXXX.json" files
#
# NOTE: apache has a protection in:
#   /etc/systemd/system/multi-user.target.wants/apache2.service
#   PrivateTmp=true
# which creates a '/tmp' in e.g. /tmp/systemd-private-*-apache2.service-*/
$config{dir_cfg}                  = File::Spec->tmpdir(); 

# full path to snapshots and temporary files, full path
$config{dir_novnc}                = "$config{dir_service}/novnc";

# MACHINE DEFAULT SETTINGS -----------------------------------------------------

# max session life time in sec. 1 day is 86400 s. Highly recommended.
#   Use 0 to disable (infinite)
$config{snapshot_lifetime}        = 86400; 

# default nb of CPU per instance.
$config{snapshot_alloc_cpu}       = 1;

# default nb of RAM per instance (in MB).
$config{snapshot_alloc_mem}       = 4096.0;

# default size of disk per instance (in GB). Only for ISO machines.
$config{snapshot_alloc_disk}      = 10.0;

# default machine to run
$config{machine}                  = 'dsl.iso';

# QEMU executable. Adapt to the architecture you run on.
$config{qemu_exec}                = "qemu-system-x86_64";

# QEMU video driver, can be "qxl" or "vmware"
$config{qemu_video}               = "qxl"; 

# SERVICE CONTRAINTS -----------------------------------------------------------

# max amount [0-1] of CPU load. Deny service when above.
$config{service_max_load}         = 0.8  ;

# max number of active sessions. Deny service when above.
$config{service_max_instance_nb}  = 10;

# allow re-entrant sessions. Safer with single-shot.
#   0: non-persistent (single-shot) are lighter for the server, but limited in use.
#   1: persistent sessions can be re-used within life-time until shutdown.
$config{service_allow_persistent} = 1;

# USER AUTHENTICATION ----------------------------------------------------------

# must use token to connect (highly recommended)
#   when false, no token is used (direct connection).
$config{service_use_vnc_token}    = 1;

# the name of the SMTP server, and optional port.
#   when empty, no email is needed, token is shown.
#   The SMTP server is used to send emails, and check user credentials.
$config{smtp_server}              = "smtp.synchrotron-soleil.fr"; 

# the SMTP port e.g. 465, 587, or left blank
# and indicate if SMTP uses encryption
$config{smtp_port}                = 587; 
$config{smtp_use_ssl}             = 'starttls'; # 'starttls' or blank

# the name of the IMAP server, and optional port.
#   when empty, no email is needed, token is shown.
#   The IMAP server is used to check user credentials.
$config{imap_server}              = 'sun-owa.synchrotron-soleil.fr'; 

# the IMAP port e.g. 993, or left blank
$config{imap_port}                = 993; 

# the name of the LDAP server.
#   The LDAP server is used to check user credentials.
$config{ldap_server}              = '195.221.10.1'; 
$config{ldap_port}                = 389; # default is 389

# the email address of the sender of the messages on the SMTP server. 
$config{email_from}               = 'luke.skywalker@synchrotron-soleil.fr';

# the password for the sender on the SMTP server, or left blank when none.
$config{email_passwd}             = "";

# how to check users

# the email authentication is less secure. Use it with caution.
#   the only test is for an "email"-like input, but not actual valid / registered email.
#   When used, you MUST make sure $config{service_use_vnc_token} = 1
#   When authenticated with email, only single-shot sessions can be launched.
$config{check_user_with_email}    = 0;  # send token via email.
$config{check_user_with_imap}     = 0;
$config{check_user_with_smtp}     = 0;
$config{check_user_with_ldap}     = 0;


# ------------------------------------------------------------------------------
# update config with input arguments from the command line (when run as script)
# ------------------------------------------------------------------------------

# the 'session_watch' can be set from the command line to watch for the end of a
# running session. Provide a full path to a JSON session file in 'cfg_dir'.
# the this script will load the session info and look for the end of the 
# associated processes. When the session ends, cleanu-up is done.
$config{session_watch}            = ""; 

# the 'service_monitor' can be set to true to generate a list of running sessions.
# each of these can display its configuration, and be stopped/cleaned.
$config{service_monitor}          = 0;

$config{session_stop}             = ""; # send a json ref, stop service

for(my $i = 0; $i < @ARGV; $i++) {
  $_ = $ARGV[$i];
  if(/--help|-h$/) {
    print STDERR "$0: launch a QEMU/KVM machine in a browser window.\n\n";
    print STDERR "Usage: $0 --option1=value1 ...\n\n";
    print STDERR "Valid options are:\n";
    foreach my $key (keys %config) {
      print STDERR "  --$key=VALUE [$config{$key}]\n";
    }
    print "\n(c) 2020 Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.\n";
    exit;
  } elsif (/^--(\w+)=(\w+)$/) {      # e.g. '--opt=value'
    if (exists($config{$1})) {
      $config{$1} = $2;
    } 
  } elsif (/^--(\w+)=([a-zA-Z0-9_\ \"\.\-\:\~\\\/]+)$/) {      # e.g. '--opt=file'
    if (exists($config{$1})) {
      $config{$1} = $2;
    } 
  }
}

if ($config{session_watch}) {
  # wait for session to end, and clean files/PIDs.
  session_watch($config{session_watch});
  exit;
}

if ($config{session_stop}) {
  # wait for session to end, and clean files/PIDs.
  my $session_ref = session_load($config{session_stop});
  session_stop($session_ref);
  exit;
}

# for I/O, to generate HTML display and email content.
my $error       = "";
my $output      = "";

# Check running snapshots and clean any left over.
$error .= service_housekeeping(\%config);  # see below for private subroutines.

# ------------------------------------------------------------------------------
# Session variables: into a hash as well.
# ------------------------------------------------------------------------------

my %session;

# transfer defaults
$session{machine}     = $config{machine};
$session{dir_snapshot}= tempdir(TEMPLATE => "$config{service}" . "_XXXXXXXX", 
  DIR => $config{dir_snapshots}) || die;
$session{name}        = File::Basename::fileparse($session{dir_snapshot});
$session{snapshot}    = "$session{dir_snapshot}/$config{service}.qcow2";
$session{json}        = "$config{dir_cfg}/$session{name}.json";

$session{user}        = "";
$session{password}    = "";
$session{persistent}  = "";  # implies lower server load
$session{cpu}         = $config{snapshot_alloc_cpu};  # cores
$session{memory}      = $config{snapshot_alloc_mem};  # in MB
$session{disk}        = $config{snapshot_alloc_disk}; # only for ISO
$session{video}       = $config{qemu_video};

$session{date}        = localtime();
# see https://www.oreilly.com/library/view/perl-cookbook/1565922433/ch11s03.html#:~:text=To%20append%20a%20new%20value,values%20for%20the%20same%20key.
#   on how to handle arrays in a hash.
# push new PID: push @{ $session{pid} }, 1234;
# get PIDs:     my @pid = @{ $session{pid} };
$session{pid}         = ();     # we search all children in session_stop
push @{ $session{pid} }, $$;    #   add our own PID
$session{pid_wait}    = $$;     # PID to wait for (daemon).
$session{port}        = 0;      # will be found automatically (6080)
$session{qemuvnc_ip}  = "127.0.0.1";
if ($config{service_use_vnc_token}) {
  # cast a random token key for VNC: 8 random chars in [a-z A-Z digits]
  sub rndStr{ join'', @_[ map{ rand @_ } 1 .. shift ] };
  $session{vnc_token} = rndStr (8, 'a'..'z', 'A'..'Z', 0..9);
} else {
  $session{vnc_token} = "";
}
$session{runs_as_cgi} = 1;
$session{url}         = "";

# ------------------------------------------------------------------------------
# Update session info from CGI
# ------------------------------------------------------------------------------

$CGI::POST_MAX  = 65535;      # max size of POST message
my $q           = new CGI;    # create new CGI object "query"
if (my $res = $q->cgi_error()){
  if ($res =~ /^413\b/o) { $error .= "Maximum data limit exceeded.\n";  }
  else {                   $error .= "An unknown error has occured.\n"; }
}

$session{remote_host} = $q->remote_host(); # the 'client'
$session{server_name} = $q->server_name(); # the 'server'

my $cgi_undef = 0;
# these are the "input" to collect from the HTML FORM.
# count how many parameters are undef. All will when running as script.
for ('machine','persistent','user','password','cpu','memory','video') {
  my $val = $q->param($_);
  if (defined($val)) {
    $session{$_} = $val;
  } else { $cgi_undef++; }
}

if ($cgi_undef > 3) { # "3" as user,password and persistent can be left undef 
  # many undefs from CGI: no HTML form connected: running as detached script
  print STDERR "Running as detached script. No token. No authentication.\n";
  $session{vnc_token}             = "";
  $session{runs_as_cgi}           = 0;
  $config{service_use_vnc_token}  = 0;
  $config{check_user_with_email}  = 0;
  $config{check_user_with_ldap}   = 0;
  $config{check_user_with_imap}   = 0;
  $config{check_user_with_smtp}   = 0;
}

# ------------------------------------------------------------------------------
# Session checks: cpu, memory, disk, VM
# ------------------------------------------------------------------------------

if (Sys::CPU::cpu_count()-Sys::CpuLoad::load() < $session{cpu}) {
  $error .= "Not enough free CPU's. Try again later.\n";
}
if (Sys::CpuLoad::load() / Sys::CPU::cpu_count() > $config{service_max_load}) {
  $error .= "Server load exceeded. Try again later.\n";
}
if (freemem() / 1024/1024 < $session{memory}) {
  $error .= "Not enough free memory. Try again later.\n";
}
if (not -e "$config{dir_machines}/$session{machine}") {
  $error .= "Can not find virtual machine.\n";
}

# assemble welcome message -----------------------------------------------------
my $ok   = '<font color=green>[OK]</font>';

# header with images, and start a list of items <li>
$output .= <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>$config{service}: $session{machine} [$session{server_name}]</title>
</head>
<body>
  <a href="http://www.synchrotron-soleil.fr" target="_top">
    <img alt="SOLEIL" title="SOLEIL"
    src="http://$session{server_name}/desktop/images/logo_soleil.png"
    align="left" border="0" height="64"></a>
  <img alt="RemoteDesktop" title="RemoteDesktop"
    src="http://$session{server_name}/desktop/images/virtualmachines.png"
    align="right" height="128" width="173">  
  <h1>$config{service}: Remote Desktop: $session{machine}</h1>
  <hr><ul>
END_HTML

# ------------------------------------------------------------------------------
# User credentials checks
# ------------------------------------------------------------------------------

{ # authentication block
  my $authenticated = "";
  $output .= "<li>$ok Hello <b>$session{user}</b> !</li>\n";
  # when all fails or is not checked, consider sending an email.
  #   must use token
  if (not $authenticated and $config{check_user_with_email} 
                         and Email::Valid->address($session{user})) {
    if (not $config{service_use_vnc_token}) {
      $error .= "Email authentication check requires a token check as well. Wrong service configuration.";
    } else {
      $authenticated = "EMAIL";
      $output .= "<li>$ok An email will be sent to indicate the token.</li>\n";
      $config{service_allow_persistent} = 0;
      $session{persistent}              = 0;
    }
  }
  if (not $authenticated and $config{check_user_with_imap}) {
    $authenticated .= session_check_imap(\%config, \%session); # checks IMAP("user","password")
  }
  if (not $authenticated and $config{check_user_with_smtp}) {
    $authenticated .= session_check_smtp(\%config, \%session); # checks SMTP("user","password")
  }
  if (not $authenticated and $config{check_user_with_ldap}) {
    $authenticated .= session_check_ldap(\%config, \%session); # checks LDAP("user","password")
  }
  # now we search for a "SUCCESS"
  if (index($authenticated, "SUCCESS") > -1) {
    $output .= "<li>$ok You are authenticated.</li>\n";
  } elsif (index($authenticated, "FAILED") > -1) {
    $error  .= "User $session{user} failed authentication. Check your username / passwword."; 
  } elsif (not $authenticated) {
    $output .= "<li><b>[WARN]</b> Service is running without user authentication.</li>\n";
    # no authentication configured...
  }
} # authentication block

$output .= "<li>$ok Starting on $session{date}</li>\n";
$output .= "<li>$ok The server name is $session{server_name}.</li>\n";
$output .= "<li>$ok You are accessing this service from $session{remote_host}.</li>\n";

if (defined($session{persistent}) and $session{persistent} =~ /yes|persistent|true|1/i) {
  $output .= "<li>$ok Using persistent session (re-entrant login).</li>\n";
  $session{persistent} = "yes";
} else {
  $output .= "<li>$ok Using non persistent session (<b>one-shot</b> login).</li>\n";
  $session{persistent} = "";
}

{ # find a free port for noVNC on server
  my $socket = IO::Socket::INET->new(Proto => 'tcp', LocalAddr => $session{qemuvnc_ip});
  $session{port} = $socket->sockport();
  $socket->close;
}
my $vnc_port = undef;
# find a another free VNC port at qemuvnc_ip
for my $port (5900..6000) {
  my $socket = IO::Socket::IP->new(PeerAddr => $session{qemuvnc_ip}, PeerPort => $port);
  if (not $socket) { 
    $vnc_port = $port;
    last;
  } else { $socket->close; }
}
if (not defined($vnc_port)) {
  $error .= "Can not find a port for the display.\n";
} 

# ==============================================================================
# DO the work
# ==============================================================================

# Create snapshot --------------------------------------------------------------
if (not $error) {

  my $cmd  = "";
  my $res  = "";
  my $http = "http://$session{server_name}/$config{service}";
  
  if ($session{machine} =~ /\.iso$/i) { # machine ends with .ISO
    $cmd      = "qemu-img create -f qcow2 $session{snapshot} $session{disk}G";
    $res      = `$cmd`; # execute command
    $output   .= "<li>$ok Will use ISO from ";
  } else {
    $cmd      = "qemu-img create -b $config{dir_machines}/$session{machine}"
              . " -f qcow2 $session{snapshot}";
    $res      = `$cmd`; # execute command
    $output  .= "<li>$ok Creating snapshot from ";
  }
  $output .= "<a href='$http/machines/$session{machine}'>"
  . "$session{machine}</a> as session $session{name}</li>\n";
  
  # check for existence of cloned VM
  sleep(1); # make sure the VM has been cloned
  if (not $error and not -e $session{snapshot}) {
    $error .= "Could not clone $session{machine} into snapshot.\n";
  }
} # Create snapshot

# LAUNCH CLONED VM -------------------------------------------------------------
my $proc_qemu  = ""; # REQUIRED killed at END
if (not $error) {
  
  # common options for QEMU
  my $cmd = "$config{qemu_exec}"
    . " -hda $session{snapshot} -smp $session{cpu} -m $session{memory}"
    . " -machine pc,accel=kvm -enable-kvm -cpu host"
    . " -net user -net nic,model=ne2k_pci -vga $session{video}";
  if ($session{machine} =~ /\.iso$/i) {
    $cmd .= " -boot d -cdrom $config{dir_machines}/$session{machine}";
  } else {
    $cmd .= " -boot c";
  }
  my $vnc_port_5900=$vnc_port-5900;
  $cmd .= " -vnc $session{qemuvnc_ip}:$vnc_port_5900";
  
  my ($token_handle, $token_name) = tempfile(UNLINK => 1);
  if ($session{vnc_token}) {
    # must avoid output to STDOUT, so redirect STDOUT to NULL.
    #   file created just for the launch, removed immediately. 
    #   Any 'pipe' such as "echo 'change vnc password\n$vnc_token\n' | qemu ..." is shown in 'ps'.
    #   With a temp file and redirection, the token does not appear in the process list (ps).

    print $token_handle "change vnc password\n$session{vnc_token}\n";
    close($token_handle);
    # redirect 'token' to QEMU monitor STDIN to set the VNC password
    $cmd .= ",password -monitor stdio > /dev/null < $token_name";
  }
  $proc_qemu = Proc::Background->new($cmd);
  if (not $proc_qemu) {
    $error  .= "Could not start QEMU/KVM for $session{machine}.\n";
  } else {
    $output .= "<li>$ok Started QEMU/KVM for $session{machine} with VNC.</li>\n";
    push @{ $session{pid} }, $proc_qemu->pid;
  }
  sleep(1);
  unlink($token_name);
} # LAUNCH CLONED VM

# LAUNCH NOVNC (do not wait for VNC to stop) -----------------------------------
my $proc_novnc  = ""; # REQUIRED killed at END
if (not $error) {
  my $cmd = "$config{dir_novnc}/utils/websockify/run" .
    " --web $config{dir_novnc} $session{port} $session{qemuvnc_ip}:$vnc_port";
  if (not $session{persistent}) { $cmd .= " --run-once"; }

  $proc_novnc = Proc::Background->new($cmd);
  if (not $proc_novnc) {
    $error .= "Could not start noVNC.\n";
  } else {
    $output .= "<li>$ok Started noVNC session $session{port}</li>\n";
    push @{ $session{pid} }, $proc_novnc->pid;
  }
}

# update all PIDs with children
push @{ $session{pid} }, uniq sort flatten(proc_getchildren($$));

# store the PID to wait for. Depends on persistent state.
if (not $error and $proc_novnc and $proc_qemu) { 
  if ($session{persistent}) { 
    $session{pid_wait} = $proc_qemu->pid;
  } else {
    $session{pid_wait} = $proc_novnc->pid;
  }
}

# save session info
session_save(\%session);

print STDERR $0.": $session{name}: PIDs:  @{$session{pid}}\n";

# COMPLETE OUTPUT MESSAGE ------------------------------------------------------
my $output_email="";  # this is the complete output
                      # "output" should omit the vnc_token
if (not $error) {
  $session{url} = "http://$session{remote_host}:$session{port}/vnc.html?host=$session{remote_host}&port=$session{port}";
  
  $output .= "<li>$ok No error, all is fine.</li>\n";
  $output .= "<li><b>$ok Connect to your machine at <a href=$session{url} target=_blank>$session{url}</b></a>.</li>\n";
  if ($session{vnc_token}) {
    $output .= "<li><b>$ok Security token is: $session{vnc_token}</b></li>\n";
  }
  if ($config{snapshot_lifetime}) {
    my $datestring = localtime(time()+$config{snapshot_lifetime});
    $output .= "<li><b>$ok You can use your machine until $datestring.</b></li>\n";
  }
  $output .= "</ul><hr>\n";
  $output .= <<END_HTML;
    <p>Hello $session{user} !</p>

    <p>Your machine $config{service} $session{machine} has just started. 
    Click on the following link and enter the associated token.</p>

    <h1><a href=$session{url} target=_blank>$session{url}</a></h1>
END_HTML
if ($session{vnc_token}) {
  $output .= "\n<h1>Token: $session{vnc_token}</h1>\n\n";
}
if (not $session{persistent} =~ /yes|persistent|true|1/i) {
  $output .= "\n<p><i>NOTE: You can only login once (non persistent).</i></p>\n";
} else {
  $output .= "\n<p><i>NOTE: You can close the browser and reconnect any time "
    . "(within life-time). Please <b>shut down the machine properly</b></i></p>.\n";
}

$output .= <<END_HTML;
    
    <p>
    Remember that: <ul>
    <li>The virtual machine is created on request, and not kept. 
      Your work <b>must be saved elsewhere</b> 
      (e.g. mounted disk, ssh/sftp, Dropbox, OwnCloud...).</li>
    <li>We recommend that you adapt the <b>screen resolution</b> of the 
      virtual machine using the bottom-left menu <i>Preferences/Monitor 
      Settings</i>.</li>
    <li>We recommend that you adapt the <b>keyboard layout</b> from the <i>Preferences</i>.
    </ul></p>
    
    <hr>
    <small><a href="http://$session{server_name}/desktop/">Remote Desktop</a> (c) 2020 - GRADES - Synchrotron Soleil - Thanks for using our data analysis services !</small>
    </body>
    </html>
END_HTML
} else {
  $output .= "</ul><hr>\n";
  $output .= "<h1>[ERROR]</h1>\n\n";
  $output .= "<p><div style='color:red'>$error</div></p>\n";
  $output .= "</body></html>\n";
}

# write index.html page with token ---------------------------------------------
my $html_name = "$session{dir_snapshot}/index.html"; # removed afterwards
{
  # when authentication is via sending an email, we remove all occurences 
  # of the token.
  my $output_no_token = $output;
  if ($config{check_user_with_email}) {
    my $rep             = "sent via email to $session{user}";
    $output_no_token =~ s/$session{vnc_token}/$rep/g;
  }
  open my $fh, ">", $html_name;
  print $fh $output_no_token;
  close $fh;
}

# send message via email when possible
if ($config{check_user_with_email}) {
  # send the full output message (with token)
  session_email(\%config, \%session, $output);
}

# display the output message (redirect) ----------------------------------------
if (not $session{runs_as_cgi}) {
  # detached script
  print STDERR $0.": $session{name}: json:  $session{json}\n";
  print STDERR $0.": $session{name}: URL:   $session{url}\n";
  print STDERR $0.": $session{name}: Token: $session{vnc_token}\n" if ($session{vnc_token});
} else {
  # running from HTML FORM
  my $redirect="http://$session{server_name}/desktop/snapshots/$session{name}/index.html";
  print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)
  sleep(5); # make sure the display comes in.
}

# remove any local footprint of the token during exec
if (-e $html_name)  { unlink $html_name; }

# Script: WAIT for QEMU/noVNC to end // CGI: launch daemon ---------------------
if (not $session{runs_as_cgi}) {
  # when running as script: wait for end of processes.
  if (not $error and $proc_novnc and $proc_qemu) { 
    if ($session{persistent}) { $proc_qemu->wait; }
    else                      { $proc_novnc->wait; }
  }
  # clean-up
  session_stop(\%session); # remove files and kill all processes
} else {
  # to display the message the CGI must end. We thus start daemon in background.
  if (not $error and $proc_novnc and $proc_qemu) { 
    my $cmd = $0." --session_watch=$session{json}";
    my $proc_watcher = Proc::Background->new($cmd);
    if (not $proc_watcher) {
      print STDERR $0.": ERROR: Could not launch daemon for $session{json}.\n";
    }
  } else {
    session_stop(\%session); # error: clean
  }
}

exit;

# final clean-up in case of error
END {
  # session_stop(\%session);
}














# ==============================================================================
# support subroutines
# - session_save:         to a JSON file with snapshot name in e.g. /tmp
# - session_load:         get session from a JSON file.
# - session_stop:         stop a session.
# - session_watch:      wait for a session to end and clean-up (as daemon).
# - session_email:        send email to user (with token).
# - session_check_smtp:   check user credentials with SMTP.
# - session_check_imap:   check user credentials with IMAP.
# - session_check_ldap:   check user credentials with LDAP.
# - service_housekeeping: clean invalid/old sessions.
# ==============================================================================

# session_save(\%session): save session hash into a JSON.
sub session_save {
  my $session_ref  = shift;
  my %session = %{ $session_ref };
  
  open my $fh, ">", $session{json};
  my $json = JSON::encode_json(\%session);
  print STDERR "[$session{date}]: $json\n";
  print $fh "$json\n";
  close $fh;
}

# $session = session_load($file): load session hash from JSON.
#   return $session reference
sub session_load {
  my $file = shift;
  
  open my $fh, "<", $file;
  my $json = <$fh>;
  close $fh;
  my $session = decode_json($json);
  return $session;
}

sub session_watch {
  my $file = shift;
  
  if (not -e $file) {
    print STDERR $0.": ERROR: session $file does not exist.\n";
  } else {
    print STDERR $0.": Watching json: $file\n";
    my $session_ref = session_load($file);
    my %session = %{ $session_ref };
    
    my $found = 1;
    while ($found) {
      $found = proc_running($session{pid_wait});
      sleep(10);
    }
    # we exit when the PID is not found.
    session_stop(\%session);
  }
} # session_watch

# session_stop(\%session): stop given session, and remove files.
sub session_stop {
  my $session_ref  = shift;
  my %session = %{ $session_ref };
  
  # remove directory and JSON config
  if ($session{dir_snapshot} and -e $session{dir_snapshot})  
    { rmtree($session{dir_snapshot}); } 
  if ($session{json} and -e $session{json})          
    { unlink($session{json}); }
  
  my $now         = localtime();
  if ($session{remote_host}) { 
    print STDERR "[$now] STOP $session{machine} started on [$session{date}] for $session{user}\@$session{remote_host}\n";
  }
  
  # make sure QEMU/noVNC and asssigned SHELLs are killed
  # sometimes, PID's can change (more forks e.g. by websocket)
  my @pids = @{ $session{pid} };
  print STDERR "[$now]   Kill @pids\n";
  map {
    my @all = flatten(proc_getchildren($_));  # get all children from that PID
    killfam('TERM', reverse uniq sort @all);  # by reverse creation date/PID
  } reverse uniq sort @pids;
  
} # session_stop

# service_housekeeping(\%config): scan 'snapshot' and 'cfg' directories.
#   - kill over-time sessions
#   - check that 'snapshots' have a 'cfg'.
#   - remove orphan 'snapshots' (may be left from a hard reboot).
# return an $error string (or empty when all is OK).
sub service_housekeeping {
  my $config_ref  = shift;
  my %config = %{ $config_ref };
  
  my $dir     = $config{dir_snapshots};
  my $cfg     = $config{dir_cfg};
  my $service = $config{service};
  
  # clean:
  # - remove orphan snapshots (no corresponding JSON file)
  # - remove snapshots that have gone above their lifetime
  foreach my $snapshot (glob("$dir/$service"."_*")) {
    
    if (-d $snapshot) { # is a snapshot directory
      my $snaphot_name = fileparse($snapshot); # just the session name
      print STDERR "$config{service}: housekeeping: $snapshot $cfg/$snaphot_name.json\n";
      if (not -e "$cfg/$snaphot_name.json") {
        # remove orphan $snapshot (no JSON)
        rmtree( $snapshot ) || print STDERR "Failed removing $snapshot";
      } elsif ($config{snapshot_lifetime} 
          and time > (stat $snapshot)[9] + $config{snapshot_lifetime}) { 
        # json exists, lifetime exceeded
        my $session_ref = session_load("$cfg/$snaphot_name.json");
        session_stop($session_ref);
      }
    }
  }
  
  # now count how many active sessions we have.
  my @jsons = glob("$cfg/$service"."_*.json");
  my $nb    = scalar(@jsons);
  my $err   = "";
  if ($nb > $config{service_max_instance_nb}) {
    $error = "Too many active sessions $nb. Max $config{service_max_instance_nb}. Try again later.";
  } else { $err = ""; }
  return $err;
} # service_housekeeping



# session_email(\%config, \%session, $output)
sub session_email {
  my $config_ref  = shift;
  my %config      = %{ $config_ref };
  my $session_ref = shift;
  my %session     = %{ $session_ref };
  my $out         = shift;

  if ($session{user} and $config{smtp_server} and $config{smtp_port}) {
    my $smtp;
    if ($config{smtp_port}) {
      $smtp= Net::SMTP->new($config{smtp_server}); # e.g. port 25
    } else {
      $smtp= Net::SMTP->new($config{smtp_server}, Port=>$config{smtp_port});
    }
    if ($smtp) {
      if ($config{email_passwd}) {
        $smtp->auth($config{email_from},$config{email_passwd});
      }
      $smtp->mail($config{email_from});
      $smtp->recipient($session{user});
      $smtp->data();
      $smtp->datasend("From: $config{email_from}\n");
      $smtp->datasend("To: $session{user}\n");
      # could add BCC to internal monitoring address $smtp->datasend("BCC: address\@example.com\n");
      $smtp->datasend("Subject: [Desktop] Remote $session{machine} connection information\n");
      $smtp->datasend("Content-Type: text/html; charset=\"UTF-8\" \n");
      $smtp->datasend("\n"); # end of header
      $smtp->datasend($out);
      $smtp->dataend;
      $smtp->quit;
    }
  }
} # session_email

# session_check_smtp($config, $session)
#   smtp_server, smtp_port, smtp_use_ssl are all needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
sub session_check_smtp {
  my $config_ref  = shift;
  my %config      = %{ $config_ref };
  my $session_ref = shift;
  my %session     = %{ $session_ref };

  # return when check can not be done
  if (not $config{check_user_with_smtp} or not $config{smtp_server} 
   or not $config{smtp_port} or not $config{smtp_use_ssl}) { return ""; }
  
  if (not $session{user} or not $session{password}) {
    return "FAILED: [SMTP] Missing Username/Password.";
  }
  
  # must use encryption to check user.
  my $smtps = Net::SMTPS->new($config{smtp_server}, Port => $config{smtp_port},  
    doSSL => $config{smtp_use_ssl}, SSL_version=>'TLSv1') 
    or return "FAILED: [SMTP] Cannot connect to server. $@"; 
    
  my $res="";

  # when USERNAME/PW is wrong, dies with no auth.
  if (not $smtps->auth ( $session{user}, $session{password} )) {
    $res = "FAILED: [SMTP] Wrong username/password (failed authentication).";
  } else { 
    $res = "SUCCESS: [SMTP] $session{user} authenticated.";
  }
  
  $smtps->quit;
  return $res;
  
  
} # session_check_smtp

# session_check_imap($config, $session)
#   imap_server, imap_port are all needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
sub session_check_imap {
  my $config_ref  = shift;
  my %config      = %{ $config_ref };
  my $session_ref = shift;
  my %session     = %{ $session_ref };
  
  my $res = "";
  
  # return when check can not be done
  if (not $config{check_user_with_imap} or not $config{imap_server} 
   or not $config{imap_port}) { return ""; }
  
  if (not $session{user} or not $session{password}) {
    return "FAILED: [IMAP] Missing Username/Password.";
  }

  # Connect to IMAP server
  my $client = Mail::IMAPClient->new(
    Server   => $config{imap_server},
    User     => $session{user},
    Password => $session{password},
    Port     => $config{imap_port},
    Ssl      =>  1,
    )
    or return "FAILED: [IMAP] Cannot authenticate username/password. $@"; # die when not auth

  # List folders on remote server (see if all is ok)
  if ($client->IsAuthenticated()) {
    $res = "SUCCESS: [IMAP] $session{user} authenticated.";
  } else {
    $res = "FAILED: [IMAP] Wrong username/password (failed authentication).";
  }

  $client->logout();
  return $res;
  
} # session_check_imap

# session_check_ldap($config, $session)
#   ldap_server is needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded

# used: http://articles.mongueurs.net/magazines/linuxmag68.html
sub session_check_ldap {
  my $config_ref  = shift;
  my %config      = %{ $config_ref };
  my $session_ref = shift;
  my %session     = %{ $session_ref };

  my $res = "";

  # return when check can not be done
  if (not $config{check_user_with_ldap} or not $config{ldap_server}
   or not $config{ldap_port}) { return ""; }

  if (not $session{user} or not $session{password}) {
    return "FAILED: [LDAP] Missing Username/Password.";
  }

  my $ldap = Net::LDAP->new($config{ldap_server}, port=>$config{ldap_port})
    or return "FAILED: [LDAP] Cannot connect to server. $@";
    
  # identify the DN
  my $mesg = $ldap->search(
    base => "dc=EXP",
    filter => "cn=$session{user}",
    attrs => ['dn']);
  
  foreach my $entry ($mesg->all_entries) {
    my $dn = $entry->dn();
    my $bmesg = $ldap->bind($dn,password=>$session{password});
    if ( $bmesg and $bmesg->code() == 0 ) {
      $res = "SUCCESS: [LDAP] $session{user} authenticated.";
    }
    else{
      my $error = $bmesg->error();
      $res = "FAILED: [LDAP] Wrong username/password (failed authentication). $error\n";
    }
  }
  
  $ldap->unbind;
  return $res;

} # session_check_ldap

# proc_getchildren($pid): return all children PID's from parent.
# use: my @children = flatten(proc_getchildren($$));
sub flatten {
  map { ref $_ ? flatten(@{$_}) : $_ } @_;
}

sub proc_getchildren {
  my $parent= shift;
  my @pid = [];
  push @pid, $parent;
  
  my $proc_table=Proc::ProcessTable->new();
  for my $proc (@{$proc_table->table()}) {
    if ($proc->ppid == $parent) {
      my $child = $proc->pid;
      push @pid, $child;
      my @pid_children = flatten(proc_getchildren($child));
      push @pid, @pid_children;
    }
  }
  return flatten(@pid);
} # proc_getchildren

# proc_running($pid): checks if $pid is running. 
#   return 0 or 1 (running).
sub proc_running {
  my $pid= shift;
  if (not $pid) { return 0; }
  
  my $found = 0; # we now search for the PID.
  my $proc_table=Proc::ProcessTable->new();
  for my $proc (@{$proc_table->table()}) {
    if ($proc->pid == $pid) {
      # session is still running
      $found = $pid;
      last;
    }
  }
  return $found;
} # proc_running

