#!/usr/bin/perl -w

# requirements:
# sudo apt install apache2 libapache2-mod-perl2
# sudo apt install libcgi-pm-perl libsys-cpu-perl libsys-cpuload-perl 
# sudo apt install libnet-dns-perl libproc-background-perl libproc-processtable-perl libemail-valid-perl
# sudo apt install qemu-kvm bridge-utils qemu iptables dnsmasq
# sudo adduser www-data kvm
# sudo chmod 755 /etc/qemu-ifup

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

use CGI;              # use CGI.pm
use File::Temp      qw/ tempfile tempdir /;
use File::Basename  qw(fileparse);
use File::Path      qw(rmtree);
use Net::Domain     qw(hostname hostfqdn);
use Net::SMTP;          # core Perl
use Sys::CPU;           # libsys-cpu-perl           for CPU::cpu_count
use Sys::CpuLoad;       # libsys-cpuload-perl       for CpuLoad::load
use Proc::Background;   # libproc-background-perl   for Background->new
use Proc::Killfam;      # libproc-processtable-perl for killfam (kill pid and children)
use Email::Valid;

# ------------------------------------------------------------------------------
# service configuration: tune for your needs
# ------------------------------------------------------------------------------

# the name of the SMTP server, and optional port
my $smtp_server  = "smtp.synchrotron-soleil.fr"; # when empty, no email is needed. token is shown.
my $smtp_port    = ""; # can be e.g. 465, 587, or left blank
# the email address of the sender of the messages on the SMTP server. Beware the @ char to appear as \@
my $email_from   = "luke.skywalker\@synchrotron-soleil.fr";
# the password for the sender on the SMTP server, or left blank
my $email_passwd = "";
my $snapshot_lifetime  = 86400; # max VM life time in sec. 1 day is 86400 s. Use 0 to disable (infinite)
my $qemu_video   = "qxl"; # can be "qxl" or "vmware"

# ==============================================================================
# DECLARE all our variables
# ==============================================================================


my $error = "";               # REQUIRED
my $output      = "";         # REQUIRED
my $datestring  = localtime(); # REQUIRED
my $novnc_port  = 0;  # REQUIRED
my $novnc_token = ""; # REQUIRED

# service stuff ----------------------------------------------------------------
my $service     = "desktop";  # REQUIRED
my $upload_base = "/var/www/html/desktop";   # root of the HTML web server area
my $upload_dir  = "$upload_base/machines"; # where to store files. Must exist.
my $upload_short = $upload_dir;
$upload_short =~ s|$upload_base/||;


my $vm          = "";   # CGI REQUIRED = machine
my $email       = "";   # CGI REQUIRED = user
my $persistent  = "no"; # CGI REQUIRED





my $lock_name   = ""; # REQUIRED, cleaned, in _XXX, filename written to indicate IP:PORT lock
my $qemuvnc_ip  = ""; # REQUIRED



# ------------------------------------------------------------------------------
# first clean up any 'old' VM sessions
# ------------------------------------------------------------------------------
my $lock_handle;  # TMP, can be made local
foreach $lock_name (glob("$upload_dir/$service.*")) {
  # test modification date for 'cloud_vm.port' file
  if ($snapshot_lifetime and time - (stat $lock_name)[9] > $snapshot_lifetime) {
    # must kill that VM and its noVNC. Read file content as a hash table
    my %configParamHash = ();
    if (open ($lock_handle, $lock_name )) {
      while ( <$lock_handle> ) { # read config in -> $configParamHash{key}
        chomp;
        s/#.*//;                # ignore comments
        s/^\s+//;               # trim heading spaces if any
        s/\s+$//;               # trim leading spaces if any
        next unless length;
        my ($_configParam, $_paramValue) = split(/\s*:\s*/, $_, 2);
        $configParamHash{$_configParam} = $_paramValue;
      }
    }
    close $lock_handle;
    # kill pid, pid_qemu and pid_vnc
    $output .= "<li>[OK] Cleaning $lock_name (time-out) in " . $configParamHash{directory} . "</li>\n";
    print STDERR "Cleaning $lock_name (time-out) " . $configParamHash{directory} . "\n";
    if ($configParamHash{pid})      { killfam('TERM',($configParamHash{pid}));      }
    if ($configParamHash{pid_qemu}) { killfam('TERM',($configParamHash{pid_qemu})); }
    if ($configParamHash{pid_vnc})  { killfam('TERM',($configParamHash{pid_vnc}));  }
    
    # clean up files/directory
    if (-e $lock_name)                   { unlink $lock_name; }
    if (-e $configParamHash{directory})  { rmtree( $configParamHash{directory} ); }
  } # if cloud_vm.port is here
}
$lock_name = "";

# ==============================================================================
# GET and CHECK input parameters
# ==============================================================================

# test if we are working from the local machine 127.0.0.1 == ::1 in IPv6)
my $fqdn         = hostfqdn(); # only used here
my $host         = hostname;   # only used here
if ($remote_host eq "::1") {
  $fqdn = "localhost";
  $host = $fqdn;
  $remote_host = $fqdn;
}
if ($fqdn eq "localhost") {
  $fqdn = inet_ntoa(
        scalar gethostbyname( $host || 'localhost' )
    );
  $host = $fqdn;
  $remote_host = $fqdn;
}
$output .= "<li>[OK] Starting on $datestring</li>\n";
$output .= "<li>[OK] The server name is $server_name.</li>\n";
$output .= "<li>[OK] You are accessing this service from $remote_host.</li>\n";

# test host load
my @cpuload = Sys::CpuLoad::load();   # only used here
my $cpunb   = Sys::CPU::cpu_count();  # only used here
my $cpuload0= $cpuload[0];            # only used here
if ($cpuload0 > 1.25*$cpunb) {
  $error .= "CPU load exceeded. Current=$cpuload0. Available=$cpunb. Try again later. ";
} else {
  $output .= "<li>[OK] Server $server_name load $cpuload0 is acceptable.</li>\n";
}


$CGI::POST_MAX = 1024*5000; # max 5M upload
my $q     = new CGI;    # REQUIRED (used here and for redirect at the end) create new CGI object
my $remote_host = $q->remote_host();
my $server_name = $q->server_name();

# testing/security
if (not $error) {
  if ($res = $q->cgi_error()){
    if ($res =~ /^413\b/o) {
      $error .= "Maximum data limit exceeded. ";
    }
    else {
      $error .= "An unknown error has occured. "; 
    }
  }
}

# now get values from the HTML form

# VM: virtual machine name
if (not $error) {
  $vm       = $q->param('machine');   # 1- VM base name, must match a $vm.ova filename
  if ( !$vm )
  {
    $error .= "There was a problem selecting the Virtual Machine. ";
  } else {
    $output .= "<li>[OK] Selected virtual machine $vm.</li>\n";
  }
}

# check input file name
my ( $name, $path ); # TMP
if (not $error) {
  ( $name, $path ) = fileparse ( $vm );
  $vm = $name;
  $vm =~ tr/ /_/;
  $vm =~ s/[^a-zA-Z0-9_.\-]//g; # safe_filename_characters
  if ( $vm =~ /^([a-zA-Z0-9_.\-]+)$/ ) {
    $vm = $1;
  } else {
    $error .= "Virtual Machine file name contains invalid characters. ";
  }
}

# a test is made to see if the port has already been allocated.
# we search the 1st free port (allow up to 99)
if (not $error) {
  my $id          = 0;
  my $id_ok       = 0;  # flag true when we found a non used IP/PORT
  for ($id=1; $id<100; $id++) {
    $novnc_port  = 6079 + $id;
    $lock_name   = "$upload_dir/$service.$novnc_port";
    $qemuvnc_ip  = "127.0.0.$id";
    if (not -e $lock_name) { $id_ok = 1; last; };  # exit loop if the ID is OK
  }
  # check for the existence of the IP:PORT pair.
  if (not $id_ok) { 
    $error .= "Can not assign port for session. Try again later. ";
  } else {
    $output .= "<li>[OK] Assigned $qemuvnc_ip:$novnc_port.</li>\n";
  }
}

# PERSISTENT: kill all when VNC quits
if (not $error) {
  $persistent = $q->param('persistent');      # 2- Persistent session
  if ($persistent eq "") {
    $output .= "<li>[OK] Using non persistent session (<b>one-shot</b> login)</li>";
    $persistent = "no";
  } elsif ($persistent eq "persistent") {
    $output .= "<li>[OK] Using persistent session (re-entrant login)</li>";
    $persistent = "yes";
  } else {
    $error .= "Wrong persistence choice '$persistent'";
  }
}

# EMAIL: required to send the ID and link. check email
if (not $error and $smtp_server) {
  $email          = $q->param('user');      # 3- Indicate your email
  if (Email::Valid->address($email))
  {
    $output .= "<li>[OK] Hello <b>$email</b> !</li>";
  }
  else
  {
    if ($smtp_server and $email_from) {
      $error .= "This service requires a valid email, not $email. Retry with one.";
    } else {
      $output .= "<li>[OK] will not send email.</li>";
    }
    $email = "";
  }
}

# ==============================================================================
# DO the work
# ==============================================================================

# define where our stuff will be (snapshot and HTML file)
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.
my $base_name   = ""; # REQUIRED full path, unlinked at end
$base_name = tempdir(TEMPLATE => "$service" . "_XXXXX", DIR => $upload_dir, CLEANUP => 1);

# initiate the HTML output
# WE OPEN A TEMPORARY HTML DOCUMENT, WRITE INTO IT, THEN REDIRECT TO IT.
# The HTML document contains some text (our output).
# This way the cgi script can launch all and the web browser display is made independent
# (else only display CGI dynamic content when script ends).
my $html_name   = ""; # can be local. unlinked at end but in basename = fullpath _XXXX
$html_name = $base_name . "/index.html";
( $name, $path ) = fileparse ( $base_name );

my $html_handle;        # TMP can be local
if (open($html_handle, '>', $html_name)) {
  # display information in the temporary HTML file

  print $html_handle <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>$service: $vm [$fqdn]</title>
</head>
<body>
  <img
    alt="SOLEIL" title="SOLEIL"
    src="http://$server_name/desktop/images/logo_soleil.png"
    align="right" border="0" height="64">
  <h1>$service: Virtual Machines: $vm</h1>
  <img alt="VirtualMachines" title="VirtualMachines"
    src="http://$server_name/desktop/images/virtualmachines.png"
    align="right" height="128" width="173">  
  <a href="http://$server_name/desktop/">Remote Desktop</a> / (c) E. Farhi Synchrotron SOLEIL (2020).
  <hr>
END_HTML
  close $html_handle;
} else {
  # this indicates 'upload' is probably not there, or incomplete installation
  $error .= "Can not open $html_name (initial open). ";
  print $error;
  exit(0);
}

# set temporary VM file (snapshot)
my $vm_name     = "";   # name of the snapshot file, full path
$vm_name = $base_name . "/$service.qcow2";

my $cmd         = "";   # TMP can be local
my $res         = "";   # TMP can be local

# CREATE SNAPSHOT FROM BASE VM IN THAT TEMPORARY FILE
if (not $error) {
  if (not -e "$upload_dir/$vm") {
    $error .= "Virtual Machine $vm file does not exist on this server. ";
  } elsif ($vm =~ /\.iso$/i) {
    $cmd = "qemu-img create -f qcow2 $vm_name 10G";
    $res = `$cmd`; # execute command
    $output .= "<li>[OK] Will use ISO from <a href='http://$server_name/desktop/machines/$vm'>$vm</a> in <a href='http://$server_name/desktop/machines/$name'>$name</a></li>\n";
  } else {
    $cmd = "qemu-img create -b $upload_dir/$vm.qcow2 -f qcow2 $vm_name";
    $res = `$cmd`; # execute command
    $output .= "<li>[OK] Created snapshot from <a href='http://$server_name/desktop/machines/$vm'>$vm</a> in <a href='http://$server_name/desktop/$name'>$name</a></li>\n";
  }
}

# check for existence of cloned VM
sleep(1); # make sure the VM has been cloned
if (not $error and not -e $vm_name) {
  $error .= "Could not clone Virtual Machine $vm into snapshot. ";
}

my $proc_qemu   = ""; # REQUIRED killed at end
  my $token_name  = "";   # REQUIRED token file name, cleaned after HTML/email sent
  
# LAUNCH CLONED VM with VMWARE video driver, KVM, and VNC, 4 cores. QXL driver may stall.
if (not $error) {
  # cast a random token key for VNC
  sub rndStr{ join'', @_[ map{ rand @_ } 1 .. shift ] };
  $novnc_token = rndStr 8, 'a'..'z', 'A'..'Z', 0..9;  # 8 random chars in [a-z A-Z digits]
  
  if ($vm =~ /\.iso$/i) {
    $cmd = "qemu-system-x86_64 -m 4096 -boot d -cdrom $upload_dir/$vm " .
      "-hda $vm_name -machine pc,accel=kvm -enable-kvm " .
      "-smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vga $qemu_video -vnc $qemuvnc_ip:1";
  } else {
    $cmd = "qemu-system-x86_64 -m 4096 -hda $vm_name -machine pc,accel=kvm -enable-kvm " .
      "-smp 4 -net user -net nic,model=ne2k_pci -cpu host -boot c -vga $qemu_video -vnc $qemuvnc_ip:1";
  }
  
  my $redirect    = ""; # TMP: can be local everywhere it is used 
  
  if ($novnc_token) {
    # must avoid output to STDOUT, so redirect STDOUT to NULL.
    # Any redirection or pipe triggers a 'sh' to launch qemu. 
    # The final 'die' only kills 'sh', not qemu. We use 'killfam' at END for this.
    # $cmd = "echo 'change vnc password\n$novnc_token\n' | " . $cmd . ",password -monitor stdio > /dev/null";
    
    # file created just for the launch, removed immediately. 
    # Any 'pipe' such as "echo 'change vnc password\n$novnc_token\n' | qemu ..." is shown in 'ps'.
    # With a temp file and redirection, the token does not appear in the process list (ps).
    $token_name = $base_name . "/token"; 
    my $token_handle;
    open($token_handle, '>', $token_name);
    print $token_handle "change vnc password\n$novnc_token\n";
    close($token_handle);
    # redirect 'token' to STDIN to set the VNC password
    $cmd .= ",password -monitor stdio > /dev/null < $token_name";
  }
  $proc_qemu = Proc::Background->new($cmd);
  if (not $proc_qemu) {
    $error .= "Could not start QEMU/KVM for $vm. ";
  } else {
    $output .= "<li>[OK] Started QEMU/VNC for $vm with VNC on $qemuvnc_ip:1</li>\n";
  }
}

# LAUNCH NOVNC (do not wait for VNC to stop)
my $proc_novnc  = ""; # REQUIRED killed at END
if (not $error) {
  $cmd= "$upload_base/novnc/utils/websockify/run" .
    " --web $upload_base/novnc/" .
    " $novnc_port $qemuvnc_ip:5901";
  if ($persistent eq "no") {
    $cmd .= " --run-once";
  }

  $proc_novnc = Proc::Background->new($cmd);
  if (not $proc_novnc) {
    $error .= "Could not start noVNC. ";
  } else {
    $output .= "<li>[OK] Started noVNC session $novnc_port to listen to $qemuvnc_ip:5901</li>\n";
  }
}

# ------------------------------------------------------------------------------
# create the output message (either OK, or error), and display it.

# display information in the temporary HTML file
if (open($html_handle, '>>', $html_name)) {

  if (not $error) {
    $redirect="http://$fqdn:$novnc_port/vnc.html?host=$fqdn&port=$novnc_port";

    print $html_handle <<END_HTML;
<ul>
$output
<li>[OK] No error, all is fine. Time-out is $snapshot_lifetime [s].</li>
<li><b>[OK]</b> Connect to your machine at <a href=$redirect target=_blank><b>$redirect</b></a>.</li>
</ul>
<p>Hello $email !</p>

<p>
Your machine $service $vm has just started. 
Open the following <a href=$redirect target=_blank>link to display its screen</a> 
(click on the <b>Connect</b> button). You will be requested to enter a <b>token</b>, which you should receive by email at $email.</p>
<p>
Remember that the virtual machine is created on request, and destroyed afterwards. You should then export any work done there-in elsewhere (e.g. mounted disk, ssh/sftp, Dropbox, OwnCloud...).
</p>
<p>
We recommend that you adapt the <b>screen resolution</b> of the virtual machine using the bottom-left menu <i>Preferences/Monitor Settings</i>. and the <b>keyboard layout</b> from the <i>Preferences</i> as well.
</p>

<h1><a href=$redirect target=_blank>$redirect</a></h1>
In case the link is not functional (I guessed wrong your computer name), try: <br>
<a href=http://$remote_host:$novnc_port/vnc.html?host=$remote_host&port=$novnc_port>http://$remote_host:$novnc_port/vnc.html?host=$remote_host&port=$novnc_port</a>

</body>
</html>
END_HTML
    close $html_handle;
    
    # we create a lock file
    if (open($lock_handle, '>', $lock_name)) {
      my $pid_qemu = $proc_qemu->pid();
      my $pid_vnc  = $proc_novnc->pid();
      print $lock_handle <<END_TEXT;
date: $datestring
service: $service
machine: $vm
pid: $$
pid_qemu: $pid_qemu
pid_vnc: $pid_vnc
ip: $qemuvnc_ip
port: $novnc_port
directory: $base_name
END_TEXT
      close $lock_handle;
    }
    # LOG in /var/log/apache2/error.log
    print STDERR "[$datestring] $service: start: QEMU $vm VNC=$qemuvnc_ip:5901 redirected to $novnc_port http://$server_name/desktop/machines/$name/index.html -> $redirect token=$novnc_token for user $email\n";
    
  } else {
    print STDERR "[$datestring] $service: ERROR: $_[0]\n";
    print $html_handle <<END_HTML;
    <ul>
      $output
      <li><b>[ERROR]</b> $error</li>
    </ul>
  </body>
  </html>
END_HTML
    close $html_handle;
  }
} else {
  $error .= "Can not open $html_name (append). ";
  print $error;
  exit(0);
}

sleep(1); # make sure the files have been created and flushed

# SEND THE HTML MESSAGE TO THE USER --------------------------------------------
if ($email and $smtp_server and $smtp_port) {
  my $smtp;
  if ($smtp_port) {
    $smtp= Net::SMTP->new($smtp_server); # e.g. port 25
  } else {
    $smtp= Net::SMTP->new($smtp_server, Port=>$smtp_port);
  }
  if ($smtp) {
    # read the HTML file and store it as a string
    my $file_content = do{local(@ARGV,$/)=$html_name;<>};
    $file_content .= "<h1>Use token '$novnc_token' to connect</h1>"; # add token
    
    if ($email_passwd) {
      $smtp->auth($email_from,$email_passwd) or $smtp = "";
    }
    if ($smtp) { $smtp->mail($email_from) or $smtp = ""; }
    if ($smtp) { $smtp->recipient($email) or $smtp = ""; }
    if ($smtp) { $smtp->data() or $smtp = ""; }
    if ($smtp) { $smtp->datasend("From: $email_from\n") or $smtp = ""; }
    if ($smtp) { $smtp->datasend("To: $email\n") or $smtp = ""; }
      # could add CC to internal monitoring address $smtp->datasend("CC: address\@example.com\n");
    if ($smtp) { $smtp->datasend("Subject: [Desktop] Virtual machine $vm connection information\n") or $smtp = ""; }
    if ($smtp) { $smtp->datasend("Content-Type: text/html; charset=\"UTF-8\" \n") or $smtp = ""; }
    if ($smtp) { $smtp->datasend("\n") or $smtp = ""; } # end of header
    if ($smtp) { $smtp->datasend($file_content) or $smtp = ""; }
    if ($smtp) { $smtp->dataend or $smtp = ""; }
    if ($smtp) { $smtp->quit or $smtp = ""; }
  }
}
if (not $smtp) {
  # when email not sent, add the token to the HTML message (else there is no output)
  if (open($html_handle, '>>', $html_name)) {
    print $html_handle <<END_HTML;
<h1>Use token '$novnc_token' to connect</h1>
END_HTML
    close $html_handle;
  }
}

# REDIRECT TO THAT TEMPORARY FILE (this is our display) ------------------------
# can be normal exec, or error message
$redirect="http://$server_name/desktop/machines/$name/index.html";
print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)
sleep(5); # make sure the display comes in.

# remove any local footprint of the token during exec
if (-e $html_name)  { unlink $html_name; }
if (-e $token_name) { unlink($token_name); } 

# WAIT for QEMU/noVNC to end ---------------------------------------------------
if (not $error and $proc_novnc and $proc_qemu) { 
  if ($persistent eq "no") { $proc_novnc->wait; }
  else { $proc_qemu->wait; }
}

# CLEAN-UP temporary files (qcow2, html), proc_qemu, proc_novnc
END {
  print STDERR "[$datestring] $service: cleanup: QEMU $vm VNC=$qemuvnc_ip:5901 redirected to $novnc_port for user $email\n";
  if (-e $vm_name)    { unlink $vm_name; }
  if (-e $html_name)  { unlink $html_name; }
  if (-e $token_name) { unlink($token_name); }
  if (-e $lock_name)  { unlink $lock_name; }
  if (-e $base_name)  { rmtree(  $base_name ); } # in case auto-clean up fails
  
  # make sure QEMU/noVNC and asssigned SHELLs are killed
  if ($proc_novnc) { killfam('TERM',($proc_novnc->pid)); $proc_novnc->die; }
  if ($proc_qemu)  { killfam('TERM',($proc_qemu->pid));  $proc_qemu->die; }
}

# ------------------------------------------------------------------------------

