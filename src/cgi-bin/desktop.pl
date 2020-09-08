#!/usr/bin/perl

# This script is triggered by a FORM or runs as a script.
# to test this script, launch from the project root level something like:
#
#   cd remote-desktop
#   perl src/cgi-bin/desktop.pl test --dir_service=src/html/desktop \
#     --dir_html=src/html --dir_snapshots=/tmp \
#     --dir_machines=src/html/desktop/machines/ 
#     --dir_novnc=$PWD/src/html/desktop/novnc/
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
# A running session with an attached JSON file can be monitored with:
#
#   perl desktop.pl --session_watch=/path/to/json
#
# A running session with an attached JSON file can be stopped with:
#
#   perl desktop.pl --session_stop=/path/to/json
#
# To stop and clear all running sessions use:
#
#   perl desktop.pl --dir_snapshots=/tmp  --session_purge=1
#
# To monitor all running sessions, use:
#
#   perl src/cgi-bin/desktop.pl --service_monitor=1
#
#
# Requirements
# ============
# sudo apt install apache2 libapache2-mod-perl2
# sudo apt install qemu-kvm bridge-utils qemu iptables dnsmasq
#
# sudo apt install libsys-cpu-perl libsys-cpuload-perl libsys-meminfo-perl \
#   libcgi-pm-perl liblist-moreutils-perl libnet-dns-perl libjson-perl\
#   libproc-background-perl libproc-processtable-perl libemail-valid-perl \
#   libnet-smtps-perl libmail-imapclient-perl libnet-ldap-perl libemail-valid-perl 
#
# (c) 2020 Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.



# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

# dependencies -----------------------------------------------------------------

use strict;
use warnings qw( all );

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
use Sys::MemInfo    qw(freemem totalmem);
use Proc::Background;   # libproc-background-perl   for Background->new
use Proc::ProcessTable; # libproc-processtable-perl
use Proc::Killfam;      # libproc-processtable-perl for killfam (kill pid and children)

use Net::SMTPS;         # libnet-smtps-perl         for smtp user check and emailing
use Mail::IMAPClient;   # libmail-imapclient-perl   for imap user check
use Net::LDAP;          # libnet-ldap-perl          for ldap user check
use Email::Valid;       # libemail-valid-perl

# see http://honglus.blogspot.com/2010/08/resolving-perl-cgi-buffering-issue.html
$| = 1;
CGI->nph(1);

# use https://perl.apache.org/docs/2.0/api/Apache2/RequestIO.html
# for flush with CGI
my $r = shift;
if (not $r or not $r->can("rflush")) {
  push @ARGV, $r; # put back into ARGV when not a RequestIO object
}

# ------------------------------------------------------------------------------
#                 service configuration: tune for your needs
# ------------------------------------------------------------------------------

# NOTE: This is where you can tune the default service configuration.
#       Adapt the path, and default VM specifications.

# we use a Hash to store the configuration. This is simpler to pass to functions.
my %config;

$config{version}                  = "20.09.08";  # year.month

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

# set a list of mounts to export into VMs.
# these are tested for existence before mounting. The QEMU mount_tag is set to 
# the last word of mount path prepended with 'host_'.
my @mounts                        = ('/mnt','/media');
$config{dir_mounts}               = [@mounts];

# MACHINE DEFAULT SETTINGS -----------------------------------------------------

# max session life time in sec. 1 day is 86400 s. Highly recommended.
#   Use 0 to disable (infinite)
$config{snapshot_lifetime}        = 86400; 

# default nb of CPU per session.
$config{snapshot_alloc_cpu}       = 1;

# default nb of RAM per session (in MB).
$config{snapshot_alloc_mem}       = 4096.0;

# default size of disk per session (in GB). Only for ISO machines.
$config{snapshot_alloc_disk}      = 10.0;

# default machine to run
$config{machine}                  = 'slax.iso';

# QEMU executable. Adapt to the architecture you run on.
$config{qemu_exec}                = "qemu-system-x86_64";

# QEMU video driver, can be "qxl" or "vmware"
$config{qemu_video}               = "qxl"; 

# searched detached GPU (via vfio-pci). Only use video part, no audio.
{
  my ($device_pci, $device_model, $device_name) = pci_devices("lspci -nnk","vga","vfio");
  $config{gpu_model}             = [@$device_model];
  $config{gpu_name}              = [@$device_name];
  $config{gpu_pci}               = [@$device_pci];
}

# SERVICE CONTRAINTS -----------------------------------------------------------

# max amount [0-1] of CPU load. Deny service when above.
$config{service_max_load}         = 0.8  ;

# max number of active sessions. Deny service when above.
$config{service_max_session_nb}   = 10;

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
$config{ldap_port}                = 389;    # default is 389
$config{ldap_domain}              = 'EXP';  # DC

# the email address of the sender of the messages on the SMTP server. 
$config{email_from}               = 'luke.skywalker@synchrotron-soleil.fr';

# the password for the sender on the SMTP server, or left blank when none.
$config{email_passwd}             = "";

# the method to use for sending messages. Can be:
#   auto    use the provided smtp/email settings to decide what to do
#   SSL     use the SMTP server, port SSL, and email_from with email_passwd
#   port    just use the server with given SMTP port
#   simple  just use the server, and port 25
$config{email_method}             = "simple";

# how to check users

# the email authentication is less secure. Use it with caution.
#   the only test is for an "email"-like input, but not actual valid / registered email.
#   When used, you MUST make sure $config{service_use_vnc_token} = 1
#   When authenticated with email, only single-shot sessions can be launched.
$config{check_user_with_email}    = 0;  # send token via email.
$config{check_user_with_imap}     = 0;  

# In case of IMAP error "Unable to connect to <server>: SSL connect attempt 
# failed error:1425F102:SSL routines:ssl_choose_client_version:unsupported protocol.
# See:
# https://stackoverflow.com/questions/53058362/openssl-v1-1-1-ssl-choose-client-version-unsupported-protocol

$config{check_user_with_smtp}     = 0;
$config{check_user_with_ldap}     = 0;

# set the list of 'admin' users that can access the Monitoring page.
# these must also be identified with their credentials.
my @admin = ('picca','farhie','roudenko','bac','ounsy','bellachehab');
$config{user_admin} = [@admin];



#                        END OF SERVICE CONFIGURATION

# ------------------------------------------------------------------------------
# update config with input arguments from the command line (when run as script)
# ------------------------------------------------------------------------------

# the 'session_watch' can be set from the command line to watch for the end of a
# running session. Provide a full path to a JSON session file in 'dir_cfg'.
# the this script will load the session info and look for the end of the 
# associated processes. When the session ends, cleanu-up is done.
$config{session_watch}            = ""; 

# the 'service_monitor' can be set to true to generate a list of running sessions.
# each of these can display its configuration, and be stopped/cleaned.
$config{service_monitor}          = 0;

$config{session_stop}             = ""; # send a json ref, stop service

$config{session_purge}            = 0;  # when true stop/clean all

$config{session_nb}               = 0;

for(my $i = 0; $i < @ARGV; $i++) {
  $_ = $ARGV[$i];
  if(/--help|-h|--version|-v$/) {
    print STDERR "$0: launch a QEMU/KVM machine in a browser window. Version $config{version}\n\n";
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
  session_watch(\%config, $config{session_watch});
  exit;
}

if ($config{session_stop}) {
  # wait for session to end, and clean files/PIDs.
  my $session_ref = session_load(\%config, $config{session_stop});
  if ($session_ref) {
    session_stop($session_ref);
  }
  exit;
}

# for I/O, to generate HTML display and email content.
my $error       = "";
my $output      = "";

# Check running snapshots and clean any left over.
{
  (my $err, my $nb) = service_housekeeping(\%config);  # see below for private subroutines.
  $error .= $err;
  $config{session_nb} = $nb;
};

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
$session{video}       = $config{qemu_video};          # driver to use
$session{gpu}         = ""; # indicates PCI GPU passthrough request when not empty

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
if ($session{remote_host} =~ "::1") {
  $session{remote_host} = "localhost";
}
$session{server_name} = $q->server_name(); # the 'server'
if ($session{server_name} =~ "::1") {
  $session{server_name} = "localhost";
}
$config{server_name} = $session{server_name};

# check input arguments values (not 'password')
for ('machine','persistent','user','cpu','memory','video','gpu') {
  my $val = $q->param($_);
  if (defined($val)) {
    if ( $val =~ /^([a-zA-Z0-9_.\-@]+)$/ ) {
      # all is fine
    } else {
      $error .= "$_ is not defined or contains invalid characters. ";
    }
  }
}

my $cgi_undef = 0;
# these are the "input" to collect from the HTML FORM.
# count how many parameters are undef. All will when running as script.
for ('machine','persistent','user','password','cpu','memory','video','gpu') {
  my $val = $q->param($_);
  if (defined($val)) {
    $session{$_} = $val;
  } else { $cgi_undef++; }
}

if ($cgi_undef > 4) {
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

# $output .= "<li>$ok Starting on $session{date}</li>\n";
# $output .= "<li>$ok The server name is $session{server_name}.</li>\n";
# $output .= "<li>$ok You are accessing this service from $session{remote_host}.</li>\n";


# service monitoring requires user authentication
if ($session{machine} =~ 'monitor') {
  $config{service_monitor} = 1;
}

if ($session{machine} =~ 'purge') {
  $config{session_purge} = 1;
}

# handle 'admin'actions
if (not $error and ($config{service_monitor} or $config{session_purge})) {
  (my $out, my $err) = session_authenticate(\%config, \%session);
  my $user  = $session{user};
  my @admin = @{ $config{user_admin} };
  if ($session{runs_as_cgi} and not $err and not grep( /^$user$/, @admin ) ) {
    $err .= "User $user is not among the 'user_admin' list";
  }
  if ($err) {
    $output .= "</ul><h1>[ERROR] $err</h1></body></html>";
  } else {
    if ($config{service_monitor}) {
      $output = service_monitor(\%config, $output);
    } elsif ($config{session_purge}) {
      $config{snapshot_lifetime} = 1;
      service_housekeeping(\%config);
      $output .= '</ul><h1>OK: Purged all</h1>';
    }
  }
  # display...
  print "Content-type:text/html\r\n\r\n";
  print "$output\n\n";
  if (defined($r)) { 
    eval {  # ignore error
      $r->rflush; 
    };
  }
    
  exit;
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

# ------------------------------------------------------------------------------
# User credentials checks
# ------------------------------------------------------------------------------
{
  (my $out, my $err) = session_authenticate(\%config, \%session);
  $output .= $out;
  $error  .= $err;
}

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
# find another free VNC port at qemuvnc_ip
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
$session{port_vnc} = $vnc_port;

# find a free GPU when requested
if (defined($session{gpu}) and $session{gpu} =~ /yes|gpu|true|1/i) { 
  # look for detached GPU PCI, and check if it is used by a running session
  $session{gpu} = "";
  foreach my $pci (@{ $config{gpu_pci} }) {
    if (not $session{gpu} and not session_use_gpu(\%config, $pci)) {
      $session{gpu} = $pci; # this is what we need to pass to qemu
    }
  }
  if ($session{gpu}) {
    $output .= "<li>$ok Assigned GPU at PCI $session{gpu}.</li>\n";
  } else {
    $error .= "Can not find a free GPU as requested. Try again without.\n";
  }
}

# ==============================================================================
# DO the work
# ==============================================================================

# NOTES: must make sure all commands redirect STDOUT to /dev/null not to collide
# with HTML generation. We use Proc::Background to launch tasks.

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
  my $cmd = "$config{qemu_exec} -smp $session{cpu} "
    . " -name $session{name}:$session{machine}"
    . " -machine pc,accel=kvm -enable-kvm -cpu host,kvm=off"
    . " -m $session{memory} -device virtio-balloon"
    . " -hda $session{snapshot} -device ich9-ahci,id=ahci"
    . " -netdev user,id=mynet0 -device virtio-net,netdev=mynet0"
    . " -vga $session{video}";
    

  # performance options: network 
  #   see: https://elinux.org/images/3/3b/Kvm-network-performance.pdf
  # should use virtio-net. e1000 is best among emulated devices
  #   -netdev user,id=mynet0 -device virtio-net,netdev=mynet0
  
  # performance options: disk
  #   -device ich9-ahci,id=ahci
  
  # performance options: memory
  #   -device virtio-balloon (allows to only assign what is used by guests)
      
  # handle ISO boot
  if ($session{machine} =~ /\.iso$/i) {
    $cmd .= " -boot d -cdrom $config{dir_machines}/$session{machine}";
  } else {
    $cmd .= " -boot c";
  }
  
  # attach GPU on pre-assigned PCI
  if ($session{gpu}) {
    $cmd .= " -device vfio-pci,host=$session{gpu},multifunction=on,x-vga=on";
  }
  
  # we add mounts using QEMU virt-9p, with tags 'host_<last_word>'
  #   see https://wiki.qemu.org/Documentation/9psetup
  # mounts are activated in the guest with:
  #   mount -t 9p -o trans=virtio,access=client [mount tag] [mount point]
  my @mounts = @{ $config{dir_mounts} };
  for(my $i = 0; $i <= $#mounts; $i++) {
    if (-d $mounts[$i]) { # mount must exist as a directory
      my $tag = (split '/', $mounts[$i])[-1];
      $cmd .= " -fsdev local,security_model=passthrough,id=fsdev$i,path=$mounts[$i] -device virtio-9p-pci,id=fs$i,fsdev=fsdev$i,mount_tag=host_$tag";
    }
  }
  
  # add QEMU internal VNC
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
  } else {
    $cmd .= ' > /dev/null';
  }
  
  # as stated in 
  # https://stackoverflow.com/questions/6024472/start-background-process-daemon-from-cgi-script
  # it is probably better to use 'batch' to launch background tasks.
  #   system("at now <<< '$cmd'")
  # $proc_qemu = system("echo '$cmd' | at now") || "";
  $proc_qemu = Proc::Background->new($cmd);
  if (not $proc_qemu) {
    $error  .= "Could not start QEMU/KVM for $session{machine}.\n";
  } else {
    # $output .= "<li>$ok Started QEMU/KVM for $session{machine} with VNC.</li>\n";
    push @{ $session{pid} }, $proc_qemu->pid;
  }
  sleep(1);
  unlink($token_name);
} # LAUNCH CLONED VM

# LAUNCH NOVNC (do not wait for VNC to stop) -----------------------------------
my $proc_novnc  = ""; # REQUIRED killed at END
if (not $error) {
  # we set a timeout for 1st connection, to make sure the session does not block
  # resources. Also, by setting a log record to the snapshot, we can add the 
  # session name to the process command line. Used for parsing PIDs.
  my $cmd = "$config{dir_novnc}/utils/websockify/run" .
    " --record=$session{dir_snapshot}/websocket.log" .
    " --web $config{dir_novnc} $session{port} $session{qemuvnc_ip}:$vnc_port";
  if (not $session{persistent}) { $cmd .= " --run-once"; }

  # $proc_novnc = system("echo '$cmd' | at now") || "";
  $proc_novnc = Proc::Background->new($cmd);
  if (not $proc_novnc) {
    $error .= "Could not start noVNC.\n";
  } else {
    # $output .= "<li>$ok Started noVNC session $session{port} (please connect within 5 min).</li>\n";
    push @{ $session{pid} }, $proc_novnc->pid;
  }
} # LAUNCH NOVNC

# update all PIDs with children
push @{ $session{pid} }, uniq sort flatten(proc_getchildren($$));

# store the PID to wait for. Depends on persistent state.
if (not $error) {
  if ($proc_novnc and $proc_qemu) { 
    if ($session{persistent}) { 
      # qemu and session{name} alow to find the PID
      $session{pid_wait} = $proc_qemu->pid;
    } else {
      # $config{dir_novnc}/utils/websockify/run and $session{port}
      $session{pid_wait} = $proc_novnc->pid;
    }
  }
  $session{url} = "http://$session{server_name}:$session{port}/vnc.html?host=$session{server_name}&port=$session{port}";
}

# save session info
session_save(\%session);

# COMPLETE OUTPUT MESSAGE ------------------------------------------------------
if (not $error) {

  # $output .= "<li>$ok No error, all is fine.</li>\n";
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
    <h1>Hello $session{user} !</h1>
    
    <p>Your machine $config{service} $session{machine} has just started. 
    Click on the following link and enter the associated token.</p>
    
    <div style="text-align: center;">
      <a href=$session{url} target=_blank>
        <img alt="$session{machine}" title="$session{machine}"
        src="http://$session{server_name}/desktop/images/logo-system.png"
        align="center" border="1" height="128">
      </a>
      <h2><a href=$session{url} target=_blank>$session{url}</a></h2>
    </div>
    
END_HTML
  if ($session{vnc_token}) {
    $output .= "\n<div style='text-align: center;'><h2>Token: $session{vnc_token}</h2></div>\n\n";
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
      virtual machine using the <i>Preferences/Monitor 
      Settings</i>.</li>
    <li>We recommend that you adapt the <b>keyboard layout</b> from the <i>Preferences</i>.</li>
    <li>This is also true for the <b>login-page</b> which has a layout option in the top right corner once the session has started. </li>
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

# send message via email when possible
if ($config{check_user_with_email}) {
  # send the full output message (with token)
  session_email(\%config, \%session, $output);
  my $rep             = "sent via email to $session{user}";
  $output =~ s/$session{vnc_token}/$rep/g;
}

# display the output message (redirect) ----------------------------------------
print STDERR $0.": $session{date}: START  $session{machine} as session $session{name}\n";
print STDERR $0.": $session{name}: json:  $session{json}\n";
print STDERR $0.": $session{name}: URL:   $session{url}\n";
print STDERR $0.": $session{name}: Token: $session{vnc_token}\n" if ($session{vnc_token});
print STDERR $0.": $session{name}: PIDs:  @{$session{pid}}\n";
if ($error) {
  print STDERR $0.": $session{name}: ERROR $error\n";
}
if ($session{runs_as_cgi}) {
  # running from HTML FORM
  # my $redirect="http://$session{server_name}/desktop/snapshots/$session{name}/index.html";
  #print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)
  print "Content-type:text/html\r\n\r\n";
  print "$output\n\n";
  if (defined($r)) { 
    eval {  # ignore error
      $r->rflush; 
    };
  }
  sleep(5); # make sure the display comes in.
}

# wait for end of processes.
if (not $error and $proc_novnc and $proc_qemu) { 
	if ($session{persistent}) { $proc_qemu->wait; }
	else                      { $proc_novnc->wait; }
}

# final clean-up in case of error. Inactivated to keep data for the watcher.
END {
  session_stop(\%session);
}














# ==============================================================================
# support subroutines
# - session_save
# - session_load
# - session_watch
# - session_stop
# - service_housekeeping
# - service_monitor
# - session_email
# - session_authenticate
# - session_check_smtp
# - session_check_imap
# - session_check_ldap
# - flatten
# - proc_getchildren
# - proc_running
# - pci_devices

# ==============================================================================

# session_save(\%session): save session hash into a JSON.
sub session_save {
  my $session_ref  = shift;
  
  if (not $session_ref) { return; }
  my %session = %{ $session_ref };

  open my $fh, ">", $session{json};
  my $json = JSON::encode_json(\%session);
  print $fh "$json\n";
  close $fh;
} # session_save

# $session = session_load(\%config, $file): load session hash from JSON.
#   return $session reference
sub session_load {
  my $config_ref  = shift;
  my $file        = shift;
  
  if (not $config_ref or not $file) { return undef; } 
  my %config      = %{ $config_ref };

  # we test if the given ref is partial (just session name)
  if (not -e $file) {
     if (-e "$config{dir_cfg}/$file" or -e "$config{dir_cfg}/$file.json") {
      $file = "$config{dir_cfg}/$file";
    }
    if (-e "$file.json") {
      $file = "$file.json";
    }
  }
  if (not -e $file) { return undef; }
  
  open my $fh, "<", $file;
  my $json = <$fh>;
  close $fh;
  my $session = decode_json($json);
  return $session;
} # session_load

# session_watch(\%config, $file): monitor json file and clean-up at end.
sub session_watch {
  my $config_ref  = shift;
  my $file        = shift;
  
  if (not $config_ref or not $file) { return; }
  my %config      = %{ $config_ref };
  
  # we test if the given ref is partial (just session name)
  if (not -e $file and -e "$config{dir_cfg}/$file") {
    $file = "$config{dir_cfg}/$file";
  } elsif (not -e $file and -e "$config{dir_cfg}/$file.json") {
    $file = "$config{dir_cfg}/$file.json";
  }
  
  if (not -e $file) {
    print STDERR $0.": ERROR: session $file does not exist.\n";
  } else {
    print STDERR $0.": Watching json: $file\n";
    my $session_ref = session_load(\%config, $file);
    if (not $session_ref) { return; }
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
  if (not $session_ref) { return; }
  
  my %session = %{ $session_ref };

  # remove directory and JSON config
  if ($session{dir_snapshot} and -e $session{dir_snapshot})  
    { rmtree($session{dir_snapshot}); } 
  if ($session{json} and -e $session{json})          
    { unlink($session{json}); }
  
  my $now         = localtime();
  if ($session{remote_host}) { 
    print STDERR "[$now] STOP $session{name} $session{machine} started on [$session{date}] for $session{user}\@$session{remote_host}\n";
  }
  
  # make sure QEMU/noVNC and asssigned SHELLs are killed
  # sometimes, PID's can change (more forks e.g. by websocket)
  if ($session{pid}) {
    my @pids = @{ $session{pid} };
    print STDERR "[$now]   Kill @pids\n";
    map {
      my @all = flatten(proc_getchildren($_));  # get all children from that PID
      killfam('TERM', reverse uniq sort @all);  # by reverse creation date/PID
    } reverse uniq sort @pids;
    sleep(1);
    map {
      my @all = flatten(proc_getchildren($_));  # get all children from that PID
      killfam('KILL', reverse uniq sort @all);  # by reverse creation date/PID
    } reverse uniq sort @pids;
  }
  
} # session_stop

# service_housekeeping(\%config): scan 'snapshot' and 'cfg' directories.
#   - kill over-time sessions
#   - check that 'snapshots' have a 'cfg'.
#   - remove orphan 'snapshots' (may be left from a hard reboot).
# return ($error,$nb) string (or empty when all is OK) and number of sessions.
sub service_housekeeping {
  my $config_ref  = shift;
  
  if (not $config_ref) { return; }
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
      
      if (not -e "$cfg/$snaphot_name.json") {
        # remove orphan $snapshot (no JSON)
        print STDERR "$config{service}: housekeeping: $snapshot\n";
        rmtree( $snapshot ) || print STDERR "Failed removing $snapshot";
      } elsif ($config{snapshot_lifetime} 
          and time > (stat $snapshot)[9] + $config{snapshot_lifetime}) { 
        # json exists, lifetime exceeded
        print STDERR "$config{service}: housekeeping: $cfg/$snaphot_name.json\n";
        my $session_ref = session_load(\%config, "$cfg/$snaphot_name.json");
        if ($session_ref) {
          session_stop($session_ref);
        }
      }
    }
  }
  
  # now count how many active sessions we have.
  my @jsons = glob("$cfg/$service"."_*.json");
  my $nb    = scalar(@jsons);
  my $err   = "";
  $config{session_nb} = $nb;
  if ($nb > $config{service_max_session_nb}) {
    $err = "Too many active sessions $nb. Max $config{service_max_session_nb}. Try again later.";
  } else { $err = ""; }
  return ($err,$nb);
} # service_housekeeping

# service_monitor(\%config, $out): present a list of running sessions as well as
#   the server usage and history.
#   return appended string $out
sub service_monitor {
  my $config_ref  = shift;
  my $out         = shift;
  
  if (not $config_ref) { return; }
  my %config = %{ $config_ref };

  # first display server ID and usage
  my $cpu_count       = Sys::CPU::cpu_count();
  my $cpu_load        = Sys::CpuLoad::load();
  my $load            = $cpu_load  / $cpu_count;
  my $free_memory_GB  = freemem()  / 1024/1024/1024;
  my $total_memory_GB = totalmem() / 1024/1024/1024;
  
  # display a table with current info
  $out .= "</ul><br><hr><br><h1>Current $config{service} service status</h1><table  border='1'>\n";
  $out .= "<tr><th>Server           </th><th>$config{server_name} running '$config{service}' version $config{version}</th></tr>\n";
  $out .= "<tr><td>#CPU total       </td><td>$cpu_count</td></tr>\n";
  $out .= "<tr><td>#CPU used        </td><td>$cpu_load</td></tr>\n";
  $out .= "<tr><td>Load [0-1]       </td><td>$load</td></tr>\n";
  $out .= "<tr><td>Total memory (GB)</td><td>$total_memory_GB</td></tr>\n";
  $out .= "<tr><td>Free memory (GB) </td><td>$free_memory_GB</td></tr>\n";
  $out .= "<tr><td>Active sessions  </td><td>$config{session_nb}</td><br>\n";
  $out .= "</table>\n";
  
  # build a table with a list of active sessions
  # {name} {machine} {user} {date} {cpu} {mem} {persistent} {url} {token} {PIDs}
  my $dir     = $config{dir_snapshots};
  my $cfg     = $config{dir_cfg};
  my $service = $config{service};
  
  $out .= "<br><hr><br><h1>Current sessions [$config{session_nb}]</h1><table  border='1'>\n";
  $out .= "<tr><th>Start Date</th><th>Name</th><th>Machine</th><th>User</th>";
  $out .= "<th>CPU </th><th>Memory</th><th>GPU</th><th>single/persist</th><th>URL</th><th>Token</th>";
  $out .= "<th>PID's </th></tr>\n";
  foreach my $snapshot (glob("$dir/$service"."_*")) {
    if (-d $snapshot) { # is a snapshot directory
      my $snaphot_name = fileparse($snapshot); # just the session name
      if (-e "$cfg/$snaphot_name.json") {
        my $session_ref = session_load(\%config, "$cfg/$snaphot_name.json");
        if ($session_ref) {
          my %session = %{ $session_ref };
          my @pids = @{ $session{pid} };
          $out .= "<tr>";
          $out .= "<td>$session{date}</td>";
          $out .= "<td>$session{name}</td>";
          $out .= "<td>$session{machine}</td>";
          $out .= "<td>$session{user}</td>";
          $out .= "<td>$session{cpu}</td>";
          $out .= "<td>$session{memory}</td>";
          if ($session{gpu}) {
            $out .= "<td>$session{gpu}</td>";
          } else { $out .= "<td></td>"; }
          if ($session{persistent}) {
            $out .= "<td>persistent</td>";
          } else { $out .= "<td>single</td>"; }
          $out .= "<td><a href='$session{url}'>URL</a></td>";
          $out .= "<td>$session{vnc_token}</td>";
          $out .= "<td>@pids</td>\n";
        }
      }
    }
  }
  $out .= "</table>";
  
  return $out;
}

# session_email(\%config, \%session, $output): send an email with URL and token
sub session_email {
  my $config_ref  = shift;
  my $session_ref = shift;
  my $out         = shift;
  
  if (not $config_ref or not $session_ref or not $out) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  if (not $session{user} or not $config{smtp_server} 
   or not $config{smtp_port}) {
    return;
  }

#   auto    use the provided smtp/email settings to decide what to do
#   SSL     use the server, port SSL, and email_from with email_passwd
#   simple  just use the server, and port 25
#   port    just use the server with given port

  my $smtp;
  my $method = $config{email_method};
  if ($method =~ 'auto') {
    if ( not $config{smtp_port} and not $config{smtp_use_ssl}) {
      $method = 'simple';
    } elsif ($config{smtp_port} and $config{smtp_use_ssl} and $config{email_passwd}) {
      $method = 'SSL';
    } else {
      $method = 'port';
    }
  }
  
  if ($method =~ 'SSL' and $config{smtp_port} and $config{smtp_use_ssl} 
    and $config{email_passwd}) {
    $smtp = Net::SMTPS->new($config{smtp_server}, Port => $config{smtp_port},  
      doSSL => $config{smtp_use_ssl}, SSL_version=>'TLSv1');
  } elsif ($method =~ 'port' and $config{smtp_port}) {
    $smtp = Net::SMTP->new($config{smtp_server}, Port=>$config{smtp_port});
  } else {
    $smtp = Net::SMTP->new($config{smtp_server}); # e.g. port 25
  } 
  
  if ($smtp) {
    if ($config{email_passwd}) {
      $smtp->auth($config{email_from},$config{email_passwd}) || return;
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

} # session_email

# ==============================================================================

# session_authenticate(\%config, \%session)
#   check user credentials with SMTP, LDAP, IMAP and sendemail.
#   return: ($out, $err)
sub session_authenticate {

  my $config_ref  = shift;
  my $session_ref = shift;
  
  if (not $config_ref or not $session_ref) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  
  my $out = "";
  my $err = "";

  if ($session{runs_as_cgi}) { # authentication block
    my $authenticated = "";
    if (not $err) {
      # $out .= "<li>$ok Hello <b>$session{user}</b> !</li>\n";
    }
    # when all fails or is not checked, consider sending an email.
    #   must use token
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_email} 
                           and Email::Valid->address($session{user})) {
      if (not $config{service_use_vnc_token}) {
        $err .= "Email authentication check requires a token check as well. Wrong service configuration. Set config 'service_use_vnc_token'=1.";
      } else {
        $authenticated = "EMAIL";
        $out .= "<li>[OK] An email will be sent to indicate the token.</li>\n";
        $config{service_allow_persistent} = 0;
        $session{persistent}              = 0;
      }
    }
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_imap}) {
      $authenticated .= session_check_imap(\%config, \%session); # checks IMAP("user","password")
    }
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_smtp}) {
      $authenticated .= session_check_smtp(\%config, \%session); # checks SMTP("user","password")
    }
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_ldap}) {
      $authenticated .= session_check_ldap(\%config, \%session); # checks LDAP("user","password")
    }
    # now we search for a "SUCCESS"
    if (index($authenticated, "SUCCESS") > -1) {
      # $out .= "<li>$ok You are authenticated: $authenticated</li>\n";
    } elsif (not $authenticated) {
      $out .= "<li><b>[WARN]</b> Service is running without user authentication.</li>\n";
      # no authentication configured...
    } else {
      $err  .= "User $session{user} failed authentication. Check your username / password:  $authenticated."; 
    }
    
    
  } # authentication block
  return ($out, $err);
  
} # session_authenticate

# session_check_smtp(\%config, \%session)
#   smtp_server, smtp_port, smtp_use_ssl are all needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
sub session_check_smtp {
  my $config_ref  = shift;
  my $session_ref = shift;
  
  if (not $config_ref or not $session_ref) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  my $res="";

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

  # when USERNAME/PW is wrong, dies with no auth.
  if (not $smtps->auth ( $session{user}, $session{password} )) {
    $res = "FAILED: [SMTP] Wrong username/password (failed authentication).";
  } else { 
    $res = "SUCCESS: [SMTP] $session{user} authenticated.";
  }
  
  $smtps->quit;
  return $res;
  
} # session_check_smtp

# session_check_imap(\%config, \%session)
#   imap_server, imap_port are all needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
sub session_check_imap {
  my $config_ref  = shift;
  my $session_ref = shift;

  if (not $config_ref or not $session_ref) { return; }
  my %config      = %{ $config_ref };
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
    Ssl      =>  1)
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

# session_check_ldap(\%config, \%session)
#   ldap_server is needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded

# used: http://articles.mongueurs.net/magazines/linuxmag68.html
sub session_check_ldap {
  my $config_ref  = shift;
  my $session_ref = shift;

  if (not $config_ref or not $session_ref) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };

  if (not %config or not %session) { return; }
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
    base => "dc=$config{ldap_domain}",
    filter => "cn=$session{user}",
    attrs => ['dn']);
  
  if (not $mesg or not $mesg->count) {
    $res = "FAILED: [LDAP] empty LDAP search.\n";
  } else {
  
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
  }
  
  $ldap->unbind;
  return $res;

} # session_check_ldap

# session_use_gpu(\%config, $pci): return true if the given PCI is used by any running session
sub session_use_gpu {
  my $config_ref  = shift;
  my $pci         = shift;

  if (not $config_ref) { return 0; }
  my %config      = %{ $config_ref };
  my $cfg     = $config{dir_cfg};
  
  # scan JSON files
  foreach my $json (glob("$cfg/*.json")) {
    
    # session exists, load JSON
    my $session_ref = session_load(\%config, $json);
    if ($session_ref) {
      my %session = %{ $session_ref };
      if ($session{gpu} =~ $pci) { return 1; } # PCI is used
    }
  }
  return 0; # no session is using that PCI slot
} # session_use_gpu

# proc_getchildren($pid): return all children PID's from parent.
# use: my @children = flatten(proc_getchildren($$));
sub flatten {
  map { ref $_ ? flatten(@{$_}) : $_ } @_;
}

sub proc_getchildren {
  my $parent= shift;
  my @pid = [];
  push @pid, $parent;
  if (not $parent) { return; }
  
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
#   input $pid is a PID number.
#   return 0 or 1 (running).
sub proc_running {
  my $pid   = shift;
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

# pci_devices($cmd,$type,$module): extract GPU info from lspci and identify the devices
#   input:  $cmd    command to execute, e.g. 'lspci -nnk'
#           $type   type of devive,     e.g. "vga" or empty (can be any word to search for)
#           $module used kernel module, e.g. "nvidia" or "vfio" or empty
#   output: list of devices matching criteria, (@$device_pci, @$device_model, @$device_name)
#
# example: my ($device_pci, $device_model, $device_name) = pci_devices("lspci -nnk","audio","");
#          print "$_\n" for @$device_pci;
# example: pci_devices("lspci -nnk","vga",  "vfio");
sub pci_devices {
  my $cmd    = shift;
  my $type   = shift;
  my $module = shift;

  my $device_found = 0;
  my @device_pci   = ();
  my @device_model = ();
  my @device_name  = ();
  my ($pci, $device, $descr, $vendor, $model);
  open(LSPCI , "$cmd|") or return (\@device_pci, \@device_model, \@device_name);
  while (my $line = <LSPCI>) {
    chomp $line;
    # we first search the device syntax has XX:YY.Z descr: text [vendor:model] rest
    if (! $device_found) {
      ($pci, $device, $descr, $vendor, $model) = $line =~
          m/(\S+)\s+ ([^:]+):\s+ ((?:(?!\s*\[\S+\:\S+\]).)+)\s* \[(\S+)\:(\S+)\] (.*)/x;
      if (defined $pci and defined $vendor and defined $model) {
        $device_found=1;
      }
    } else {
      # now we search for the driver in use, not in a PCI address line
      my ($before, $kernel) = split(':\s*', $line);
      if ($before =~ /kernel/i) {
        if ((not $module or $kernel =~ /$module/i) and $pci and (not $type or $device =~ /$type/i)) {
          push @device_pci,   $pci;
          push @device_model, "$vendor:$model";
          push @device_name,  "$device $descr";
          print "[$type $kernel] PCI=$pci hardware=$vendor:$model is '$descr'\n";
        }
        $device_found=0;
      }
    }
  }
  close(LSPCI);
  return (\@device_pci, \@device_model, \@device_name);
} # pci_devices
