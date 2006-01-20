#! --PERL--
# sympa.pl - This script is the main one ; it runs as a daemon and does
# the messages/commands processing
# RCS Identication ; $Revision$ ; $Date$ 
#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

use strict;

use lib '--LIBDIR--';
#use Getopt::Std;
use Getopt::Long;

use Mail::Address;
use File::Path;

use Commands;
use Conf;
use Language;
use Log;
use Version;
use mail;
use MIME::QuotedPrint;
use List;
use Message;
use admin;
use Config_XML;
use Family;
use report;
use File::Copy;

require 'tools.pl';
require 'tt2.pl';
require 'parser.pl';

# durty global variables
my $is_signed = {}; 
my $is_crypted ;
# log_level is a global var, can be set by sympa.conf, robot.conf, list/config, --log_level or $PATHINFO  


## Internal tuning
# delay between each read of the digestqueue
my $digestsleep = 5; 

## Init random engine
srand (time());

my $version_string = "Sympa version is $Version\n";

my $usage_string = "Usage:
   $0 [OPTIONS]

Options:
   -d, --debug                           : sets Sympa in debug mode 
   -f, --config=FILE                     : uses an alternative configuration file
   --import=list\@dom                    : import subscribers (read from STDIN)
   -k, --keepcopy=dir                    : keep a copy of incoming message
   -l, --lang=LANG                       : use a language catalog for Sympa
   -m, --mail                            : log calls to sendmail
   --service == process_command|process_message  : process dedicated to messages distribution or to commands (default both)
   --dump=list\@dom|ALL                  : dumps subscribers 
   --make_alias_file                     : create file in /tmp with all aliases (usefull when aliases.tpl is changed)
   --lowercase                           : lowercase email addresses in database
   --create_list --robot=robot_name --input_file=/path/to/file.xml 
                                         : create a list with the xml file under robot_name
   --instantiate_family=family_name  --robot=robot_name --input_file=/path/to/file.xml       
                                         : instantiate family_name lists described in the file.xml under robot_name,
                                           the family directory must exist
  --add_list=family_name --robot=robot_name --input_file=/path/to/file.xml
                                         : add the list described by the file.xml under robot_name, to the family
                                           family_name.
   --modify_list=family_name --robot=robot_name --input_file=/path/to/file.xml
                                         : modify the existing list installed under the robot_name robot and that 
                                           belongs to family_name family. The new description is in the file.xml
   --close_family=family_name --robot=robot_name 
                                         : close lists of family_name family under robot_name.      

   --close_list=listname\@robot          : close a list
   --log_level=LEVEL                     : sets Sympa log level

   -h, --help                            : print this help
   -v, --version                         : print version number

Sympa is a mailinglists manager and comes with a complete (user and admin)
web interface. Sympa  can be linked to an LDAP directory or an RDBMS to 
create dynamic mailing lists. Sympa provides S/MIME and HTTPS based authentication and
encryption.
";

## Check --dump option
my %options;
unless (&GetOptions(\%main::options, 'dump=s', 'debug|d', ,'log_level=s','foreground', 'service=s','config|f=s', 
		    'lang|l=s', 'mail|m', 'keepcopy|k=s', 'help', 'version', 'import=s','make_alias_file','lowercase',
		    'close_list=s','create_list','instantiate_family=s','robot=s','add_list=s','modify_list=s','close_family=s',
		    'input_file=s')) {
    &fatal_err("Unknown options.");
}

if ($main::options{'debug'}) {
    $main::options{'log_level'} = 2 unless ($main::options{'log_level'});
}
# Some option force foreground mode
$main::options{'foreground'} = 1 if ($main::options{'debug'} ||
                                     $main::options{'version'} || 
				     $main::options{'import'} ||
				     $main::options{'help'} || 
				     $main::options{'make_alias_file'} || 
				     $main::options{'lowercase'} || 
				     $main::options{'dump'} ||
				     $main::options{'close_list'} ||
				     $main::options{'create_list'} ||
				     $main::options{'instantiate_family'} ||
				     $main::options{'add_list'} ||
				     $main::options{'modify_list'} ||
				     $main::options{'close_family'});

## Batch mode, ie NOT daemon
 $main::options{'batch'} = 1 if ($main::options{'dump'} || 
				 $main::options{'help'} ||
				 $main::options{'version'} || 
				 $main::options{'import'} || 
				 $main::options{'make_alias_file'} ||
				 $main::options{'lowercase'} ||
				 $main::options{'close_list'} ||
				 $main::options{'create_list'} ||
				 $main::options{'instantiate_family'} ||
				 $main::options{'add_list'} ||
				 $main::options{'modify_list'} ||
				 $main::options{'close_family'});

$log_level = $main::options{'log_level'} if ($main::options{'log_level'}); 

my @parser_param = ($*, $/);
my %loop_info;
my %msgid_table;

# this loop is run foreach HUP signal received
my $signal = 0;

local $main::daemon_usage; 

while ($signal ne 'term') { #as long as a SIGTERM is not received }

my $config_file = $main::options{'config'} || '--CONFIG--';
## Load configuration file
unless (Conf::load($config_file)) {
   &fatal_err("Configuration file $config_file has errors.");
}

## Open the syslog and say we're read out stuff.
do_openlog($Conf{'syslog'}, $Conf{'log_socket_type'}, 'sympa');

# setting log_level using conf unless it is set by calling option
if ($main::options{'log_level'}) {
    do_log('info', "Configuration file read, log level set using options : $log_level"); 
}else{
    $log_level = $Conf{'log_level'};
    do_log('info', "Configuration file read, default log level  $log_level"); 
}


## Probe Db if defined
if ($Conf{'db_name'} and $Conf{'db_type'}) {
    unless ($List::use_db = &List::probe_db()) {
	&fatal_err('Database %s defined in sympa.conf has not the right structure or is unreachable. If you don\'t use any database, comment db_xxx parameters in sympa.conf', $Conf{'db_name'});
    }
}

## Apply defaults to %List::pinfo
&List::_apply_defaults();

&tools::ciphersaber_installed();

if (&tools::cookie_changed($Conf{'cookie'})) {
     &fatal_err("sympa.conf/cookie parameter has changed. You may have severe inconsitencies into password storage. Restore previous cookie or write some tool to re-encrypt password in database and check spools contents (look at $Conf{'etc'}/cookies.history file)");
}

## Set locale configuration
$main::options{'lang'} =~ s/\.cat$//; ## Compatibility with version < 2.3.3
$Language::default_lang = $main::options{'lang'} || $Conf{'lang'};

## Main program
if (!chdir($Conf{'home'})) {
   fatal_err("Can't chdir to %s: %m", $Conf{'home'});
   ## Function never returns.
}
if ($main::options{'service'} eq 'process_message') {
    $main::daemon_usage = 'message';
}elsif ($main::options{'service'} eq 'process_command') {
    $main::daemon_usage = 'command';
}else{
    $main::daemon_usage = 'command_and_message'; # default is to run one sympa.pl server for both commands and message 
}

if ($signal ne 'hup') {
    ## Put ourselves in background if we're not in debug mode. That method
    ## works on many systems, although, it seems that Unix conceptors have
    ## decided that there won't be a single and easy way to detach a process
    ## from its controlling tty.
    unless ($main::options{'foreground'}) {
	if (open(TTY, "/dev/tty")) {
	    ioctl(TTY, 0x20007471, 0);         # XXX s/b &TIOCNOTTY
	    #       ioctl(TTY, &TIOCNOTTY, 0);
	    close(TTY);
	}
	open(STDIN, ">> /dev/null");
	open(STDERR, ">> /dev/null");
	open(STDOUT, ">> /dev/null");
	setpgrp(0, 0);
	# start the main sympa.pl daemon

	if (($Conf{'distribution_mode'} eq 'single') || ($main::daemon_usage ne 'command_and_message')){ 
	    printf STDERR "Starting server for $main::daemon_usage\n";
	    do_log('debug', "Starting server for $main::daemon_usage");
	    if ((my $child_pid = fork) != 0) {
		do_log('debug', "Server for $main::daemon_usage started, pid $child_pid, exiting from initial process");
		exit(0);
	    }
	}else{
	    $main::daemon_usage = 'command'; # fork sympa.pl dedicated to commands
	    do_log('debug', "Starting server for commands");
	    if ((my $child_pid = fork) != 0) {
		do_log('info', "Server for commands started, pid $child_pid");
		$main::daemon_usage = 'message'; # main process continue in order to fork
		do_log('debug', "Starting server for messages");	    
		if ((my $child_pid = fork) != 0) {
		    do_log('debug', "Server for messages started, pid $child_pid, exiting from initial process");
		    exit(0);	# exit from main process	
		}	
	    }
	}
    }

    my $service = 'sympa';
    $service .= '(message)' if ($main::daemon_usage eq 'message');
    $service .= '(command)' if ($main::daemon_usage eq 'command');
    do_openlog($Conf{'syslog'}, $Conf{'log_socket_type'}, $service);

    do_log('debug', "Running server $$ with main::daemon_usage = $main::daemon_usage ");
    unless ($main::options{'batch'} ) {
	## Create and write the pidfile
	my $file = $Conf{'pidfile'};
	$file = $Conf{'pidfile_distribute'} if ($main::daemon_usage eq 'message') ;
	&tools::write_pid($file, $$);
    }	


    # Set the UserID & GroupID for the process
    $( = $) = (getgrnam('--GROUP--'))[2];
    $< = $> = (getpwnam('--USER--'))[2];

    ## Required on FreeBSD to change ALL IDs(effective UID + real UID + saved UID)
    &POSIX::setuid((getpwnam('--USER--'))[2]);
    &POSIX::setgid((getgrnam('--GROUP--'))[2]);

    # Sets the UMASK
    umask(oct($Conf{'umask'}));

 ## Most initializations have now been done.
    do_log('notice', "Sympa $Version started");
}else{
    do_log('notice', "Sympa $Version reload config");
    $signal = '0';
}

## Check for several files.
unless (&Conf::checkfiles()) {
   fatal_err("Missing files. Aborting.");
   ## No return.
}

## Daemon called for dumping subscribers list
if ($main::options{'dump'}) {
    
    my ($all_lists, $list);
    if ($main::options{'dump'} eq 'ALL') {
	$all_lists = &List::get_lists('*');
    }else {	

	## The parameter can be a list address
	unless ($main::options{'dump'} =~ /\@/) {
	    &do_log('err','Incorrect list address %s', $main::options{'dump'});
	    exit;
	} 

	my $list = new List ($main::options{'dump'});
	unless (defined $list) {
	    &do_log('err','Unknown list %s', $main::options{'dump'});
	    exit;
	}
	push @$all_lists, $list;
    }

    foreach my $list (@$all_lists) {
	unless ($list->dump()) {
	    printf STDERR "Could not dump list(s)\n";
	}
    }

    exit 0;
}elsif ($main::options{'help'}) {
    print $usage_string;
    exit 0;
}elsif ($main::options{'make_alias_file'}) {
    my $all_lists = &List::get_lists('*');
    unless (open TMP, ">/tmp/sympa_aliases.$$") {
	printf STDERR "Unable to create tmp/sympa_aliases.$$, exiting\n";
	exit;
    }
    printf TMP "#\n#\tAliases for all Sympa lists open (but not for robots)\n#\n";
    close TMP;
    foreach my $list (@$all_lists) {
	system ("--SBINDIR--/alias_manager.pl add $list->{'name'} $list->{'domain'} /tmp/sympa_aliases.$$") if ($list->{'admin'}{'status'} eq 'open');
    }
    printf ("Sympa aliases file is /tmp/sympa_aliases.$$ file made, you probably need to installed it in your SMTP engine\n");
    
    exit 0;
}elsif ($main::options{'version'}) {
    print $version_string;
    
    exit 0;
}elsif ($main::options{'import'}) {
    my ($list, $total);

    ## The parameter should be a list address
    unless ($main::options{'import'} =~ /\@/) {
	&do_log('err','Incorrect list address %s', $main::options{'import'});
	exit;
    } 


    unless ($list = new List ($main::options{'import'})) {
	fatal_err('Unknown list name %s', $main::options{'import'});
    }

    ## Read imported data from STDIN
    while (<STDIN>) {
	next if /^\s*$/;
	next if /^\s*\#/;

	unless (/^\s*((\S+|\".*\")@\S+)(\s*(\S.*))?\s*$/) {
	    printf STDERR "Not an email address: %s\n", $_;
	}

	my $email = lc($1);
	my $gecos = $4;
	my $u;
	my $defaults = $list->get_default_user_options();
	%{$u} = %{$defaults};
	$u->{'email'} = $email;
	$u->{'gecos'} = $gecos;

	unless ($list->add_user($u)) {
	    printf STDERR "\nCould not add %s\n", $email;
	    next;
	}
	print STDERR '+';
	
	$total++;	
    }
    
    printf STDERR "Total imported subscribers: %d\n", $total;

    exit 0;
}elsif ($main::options{'lowercase'}) {
    
    unless ($List::use_db) {
	&fatal_err("You don't have a database setup, can't lowercase email addresses");
    }

    print STDERR "Working on user_table...\n";
    my $total = &List::lowercase_field('user_table', 'email_user');

    print STDERR "Working on subscriber_table...\n";
    $total += &List::lowercase_field('subscriber_table', 'user_subscriber');

    unless (defined $total) {
	&fatal_err("Could not work on dabatase");
    }

    printf STDERR "Total lowercased rows: %d\n", $total;

    exit 0;
}elsif ($main::options{'close_list'}) {

    my ($listname, $robotname) = split /\@/, $main::options{'close_list'};
    my $list = new List ($listname, $robotname);

    unless (defined $list) {
	print STDERR "Incorrect list name $main::options{'close_list'}\n";
	exit 1;
    }

    if ($list->{'admin'}{'family_name'}) {
 	unless($list->set_status_family_closed('close_list',$list->{'name'})) {
 	    print STDERR "Could not close list $main::options{'close_list'}\n";
 	    exit 1;	
 	}
    } else {
	unless ($list->close()) {
	    print STDERR "Could not close list $main::options{'close_list'}\n";
	    exit 1;	
	}
    }

    printf STDOUT "List %s has been closed, aliases have been removed\n", $list->{'name'};
    
    exit 0;
}elsif ($main::options{'create_list'}) {
    
    my $robot = $main::options{'robot'} || $Conf{'host'};
    
    unless ($main::options{'input_file'}) {
 	print STDERR "Error : missing 'input_file' parameter\n";
 	exit 1;
    }

    unless (open INFILE, $main::options{'input_file'}) {
	print STDERR "Unable to open $main::options{'input_file'}) file";
 	exit 1;	
    }
    
    my $config = new Config_XML(\*INFILE);
    unless (defined $config->createHash()) {
 	print STDERR "Error in representation data with these xml data\n";
 	exit 1;
    } 
    
    my $hash = $config->getHash();
    
    close INFILE;

    my $resul = &admin::create_list_old($hash->{'config'},$hash->{'type'},$robot);
    unless (defined $resul) {
 	print STDERR "Could not create list with these xml data\n";
 	exit 1;
    }
    
    if ($resul->{'aliases'} == 1) {
 	printf STDOUT "List has been created \n";
 	exit 0;
    }else {
 	printf STDOUT "List has been created, required aliases :\n $resul->{'aliases'} \n";
 	exit 0;
    }
}elsif ($main::options{'instantiate_family'}) {
    
    my $robot = $main::options{'robot'} || $Conf{'host'};

    my $family_name;
    unless ($family_name = $main::options{'instantiate_family'}) {
 	print STDERR "Error : missing family parameter\n";
 	exit 1;
    }
    my $family;
    unless ($family = new Family($family_name,$robot)) {
 	print STDERR "The family $family_name does not exist, impossible instantiation\n";
 	exit 1;
    }

    unless ($main::options{'input_file'}) {
 	print STDERR "Error : missing input_file parameter\n";
 	exit 1;
    }

    unless (-r $main::options{'input_file'}) {
	print STDERR "Unable to read $main::options{'input_file'}) file";
 	exit 1;	
    }

    unless ($family->instantiate($main::options{'input_file'})) {
 	print STDERR "\nImpossible family instantiation : action stopped \n";
 	exit 1;
    } 
        
    my $string = $family->get_instantiation_results();
    close INFILE;
    print STDERR $string;
    
    exit 0;
}elsif ($main::options{'add_list'}) {
     
    my $robot = $main::options{'robot'} || $Conf{'host'};

    my $family_name;
    unless ($family_name = $main::options{'add_list'}) {
	print STDERR "Error : missing family parameter\n";
 	exit 1;
    }
    
    print STDOUT "\n************************************************************\n";
    
    my $family;
    unless ($family = new Family($family_name,$robot)) {
 	print STDERR "The family $family_name does not exist, impossible to add a list\n";
 	exit 1;
    }
    
    unless ($main::options{'input_file'}) {
 	print STDERR "Error : missing 'input_file' parameter\n";
 	exit 1;
    }

    unless (open INFILE, $main::options{'input_file'}) {
	print STDERR "\n Impossible to open input file  : $! \n";
 	exit 1;	
    }

    my $result;
    unless ($result = $family->add_list(\*INFILE)) {
 	print STDERR "\nImpossible to add a list to the family : action stopped \n";
 	exit 1;
    } 
    
    print STDOUT "\n************************************************************\n";
    
    unless (defined $result->{'ok'}) {
 	print STDERR "$result->{'string_info'}";
 	print STDERR "\n The action has been stopped because of error :\n";
 	print STDERR "$result->{'string_error'}";
 	exit 1;
    }
    
    close INFILE;

    print STDOUT $result->{'string_info'};
    exit 0;
}

##########################################
elsif ($main::options{'modify_list'}) {
    
    my $robot = $main::options{'robot'} || $Conf{'host'};

    my $family_name;
    unless ($family_name = $main::options{'modify_list'}) {
 	print STDERR "Error : missing family parameter\n";
 	exit 1;
    }
    
    print STDOUT "\n************************************************************\n";
    
    my $family;
    unless ($family = new Family($family_name,$robot)) {
 	print STDERR "The family $family_name does not exist, impossible to modify the list.\n";
 	exit 1;
    }
    
    unless ($main::options{'input_file'}) {
 	print STDERR "Error : missing input_file parameter\n";
 	exit 1;
    }

    unless (open INFILE, $main::options{'input_file'}) {
	print STDERR "Unable to open $main::options{'input_file'}) file";
 	exit 1;	
    }

    my $result;
    unless ($result = $family->modify_list(\*INFILE)) {
 	print STDERR "\nImpossible to modify the family list : action stopped. \n";
 	exit 1;
    } 
    
    print STDOUT "\n************************************************************\n";
    
    unless (defined $result->{'ok'}) {
 	print STDERR "$result->{'string_info'}";
 	print STDERR "\nThe action has been stopped because of error :\n";
 	print STDERR "$result->{'string_error'}";
 	exit 1;
    }

    close INFILE;
    
    print STDOUT $result->{'string_info'};
    exit 0;
}

##########################################
elsif ($main::options{'close_family'}) {
    
    my $robot = $main::options{'robot'} || $Conf{'host'};

    my $family_name;
    unless ($family_name = $main::options{'close_family'}) {
 	print STDERR $usage_string;
 	exit 1;
    }
    my $family;
    unless ($family = new Family($family_name,$robot)) {
 	print STDERR "The family $family_name does not exist, impossible family closure\n";
 	exit 1;
    }
    
    my $string;
    unless ($string = $family->close()) {
 	print STDERR "\nImpossible family closure : action stopped \n";
 	exit 1;
    } 
    
    print STDOUT $string;
    exit 0;
}
 

## Maintenance
## Update DB structure or content if required
&List::maintenance();

## Do we have right access in the directory
if ($main::options{'keepcopy'}) {
    if (! -d $main::options{'keepcopy'}) {
	&do_log('notice', 'Cannot keep a copy of incoming messages : %s is not a directory', $main::options{'keepcopy'});
	delete $main::options{'keepcopy'};
    }elsif (! -w $main::options{'keepcopy'}) {
	&do_log('notice','Cannot keep a copy of incoming messages : no write access to %s', $main::options{'keepcopy'});
	delete $main::options{'keepcopy'};
    }
}

## Catch SIGTERM, in order to exit cleanly, whenever possible.
$SIG{'TERM'} = 'sigterm';
$SIG{'HUP'} = 'sighup';
$SIG{'PIPE'} = 'IGNORE'; ## Ignore SIGPIPE ; prevents sympa.pl from dying

my $index_queuedigest = 0; # verify the digest queue
my $index_cleanqueue = 0; 
my @qfile;

my $spool = $Conf{'queue'};
# if daemon is dedicated to message change the current spool
$spool = $Conf{'queuedistribute'} if ($main::daemon_usage eq 'message');

## This is the main loop : look after files in the directory, handles
## them, sleeps a while and continues the good job.
while (!$signal) {

    # setting log_level using conf unless it is set by calling option
    unless ($main::options{'log_level'}) {
	$log_level = $Conf{'log_level'};
	# do_log('notice', "Reset default log level  $log_level"); 
    }
    

    &Language::SetLang($Language::default_lang);

    &List::init_list_cache();

    if (!opendir(DIR, $spool)) {
	fatal_err("Can't open dir %s: %m", $spool); ## No return.
    }
    @qfile = sort grep (!/^\./,readdir(DIR));
    closedir(DIR);

    unless ($main::daemon_usage eq 'command')  { # process digest only in distribution mode
	## Scan queuedigest
	if ($index_queuedigest++ >=$digestsleep){
	    $index_queuedigest=0;
	    &SendDigest();
	}
    }
    unless ($main::daemon_usage eq 'message') { # process expire and bads only in command mode 
    
	## Clean queue (bad)
	if ($index_cleanqueue++ >= 100){
	    $index_cleanqueue=0;
	    &CleanSpool("$spool/bad", $Conf{'clean_delay_queue'});
	    &CleanSpool($Conf{'queuemod'}, $Conf{'clean_delay_queuemod'});
	    &CleanSpool($Conf{'queueauth'}, $Conf{'clean_delay_queueauth'});
	    &CleanSpool($Conf{'queuetopic'}, $Conf{'clean_delay_queuetopic'});
	}
    }
    my $filename;
    my $listname;
    my $robot;

    my $highest_priority = 'z'; ## lowest priority
    
    ## Scans files in queue
    ## Search file with highest priority
    foreach my $t_filename (sort @qfile) {
	my $priority;
	my $type;
	my $list;
	my ($t_listname, $t_robot);

	# trying to fix a bug (perl bug ??) of solaris version
	($*, $/) = @parser_param;

	## test ever if it is an old bad file
	if ($t_filename =~ /^BAD\-/i){
 	    my $queue = &Conf::get_robot_conf($robot, 'queue');
 	    if ((stat "$queue/$t_filename")[9] < (time - &Conf::get_robot_conf($robot, 'clean_delay_queue')*86400) ){
 		unlink ("$queue/$t_filename") ;
		&do_log('notice',"Deleting bad message %s because too old", $t_filename);
	    };
	    next;
	}

	## z and Z are a null priority, so file stay in queue and are processed
	## only if renamed by administrator
	next unless ($t_filename =~ /^(\S+)\.\d+\.\d+$/);

	## Don't process temporary files created by queue (T.xxx)
	next if ($t_filename =~ /^T\./);

	($t_listname, $t_robot) = split(/\@/,$1);
	
	$t_listname = lc($t_listname);
	if ($t_robot) {
	    $t_robot=lc($t_robot);
	}else{
	    $t_robot = lc(&Conf::get_robot_conf($robot, 'host'));
	}

	my $list_check_regexp = &Conf::get_robot_conf($robot,'list_check_regexp');

	if ($t_listname =~ /^(\S+)-($list_check_regexp)$/) {
	    ($t_listname, $type) = ($1, $2);
	}

	# (sa) le terme "(\@$Conf{'host'})?" est inutile
	#unless ($t_listname =~ /^(sympa|$Conf{'listmaster_email'}|$Conf{'email'})(\@$Conf{'host'})?$/i) {
	#    $list = new List ($t_listname);
	#}

	my $email = &Conf::get_robot_conf($robot, 'email');	

	if ($t_listname eq $Conf{'listmaster_email'}) {
	    ## highest priority
	    $priority = 0;
	}elsif ($type eq 'request') {
	    $priority = &Conf::get_robot_conf($robot, 'request_priority');
	}elsif ($type eq 'owner') {
	    $priority = &Conf::get_robot_conf($robot, 'owner_priority');
	}elsif ($t_listname =~ /^(sympa|$email)(\@$Conf{'host'})?$/i) {	
	    $priority = &Conf::get_robot_conf($robot,'sympa_priority');
	}else {
	    my $list =  new List ($t_listname, $t_robot, {'just_try' => 1});
	    if ($list) {
		$priority = $list->{'admin'}{'priority'};
	    }else {
		$priority = &Conf::get_robot_conf($robot, 'default_list_priority');
	    }
	}
	
	if (ord($priority) < ord($highest_priority)) {
	    $highest_priority = $priority;
	    $filename = $t_filename;
	}
    } ## END of spool lookup

    &mail::reaper;

    unless ($filename) {
	sleep(&Conf::get_robot_conf($robot, 'sleep'));
	next;
    }

    &do_log('debug', "Processing %s/%s with priority %s", &Conf::get_robot_conf($robot, 'queue'),$filename, $highest_priority) ;
    
    if ($main::options{'mail'} != 1) {
	$main::options{'mail'} = $robot if (&Conf::get_robot_conf($robot, 'log_smtp'));
    }

    ## Set NLS default lang for current message
    $Language::default_lang = $main::options{'lang'} || &Conf::get_robot_conf($robot, 'lang');

    my $queue = &Conf::get_robot_conf($robot, 'queue');
    my $status = &DoFile("$queue/$filename");
    
    if (defined($status)) {
	&do_log('debug', "Finished %s", "$queue/$filename") ;

	if ($main::options{'keepcopy'}) {
	    unless (&File::Copy::copy($queue.'/'.$filename, $main::options{'keepcopy'}.'/'.$filename) ) {
 		&do_log('notice', 'Could not rename %s to %s: %s', "$queue/$filename", $main::options{'keepcopy'}."/$filename", $!);
	    }
	}
	unlink("$queue/$filename");
    }else {
	my $bad_dir = "$queue/bad";
	
	if (-d $bad_dir) {
	    unless (rename("$queue/$filename", "$bad_dir/$filename")){
		&fatal_err("Exiting, unable to rename bad file $filename to $bad_dir/$filename (check directory permission)");
	    }
	    do_log('notice', "Moving bad file %s to bad/", $filename);
	}else{
	    do_log('notice', "Missing directory '%s'", $bad_dir);
	    unless (rename("$queue/$filename", "$queue/BAD-$filename")) {
		&fatal_err("Exiting, unable to rename bad file $filename to BAD-$filename");
	    }
	    do_log('notice', "Renaming bad file %s to BAD-%s", $filename, $filename);
	}	
    }

} ## END of infinite loop

## Dump of User files in DB
#List::dump();

## Disconnect from Database
List::db_disconnect if ($List::dbh);

} #end of block while ($signal ne 'term'){

do_log('notice', 'Sympa exited normally due to signal');
unless (unlink $Conf{'pidfile'}) {
    fatal_err("Could not delete %s, exiting", $Conf{'pidfile'});
    ## No return.
}
exit(0);


############################################################
# sigterm
############################################################
#  When we catch SIGTERM, just changes the value of the $signal 
#  loop variable.
#  
# IN : -
#      
# OUT : -
#
############################################################
sub sigterm {
    &do_log('notice', 'signal TERM received, still processing current task');
    $signal = 'term';
}


############################################################
# sighup
############################################################
#  When we catch SIGHUP, changes the value of the $signal 
#  loop variable and puts the "-mail" logging option
#  
# IN : -
#      
# OUT : -
#
###########################################################
sub sighup {
    if ($main::options{'mail'}) {
	&do_log('notice', 'signal HUP received, switch of the "-mail" logging option and continue current task');
	undef $main::options{'mail'};
    }else{
	&do_log('notice', 'signal HUP received, switch on the "-mail" logging option and continue current task');
	$main::options{'mail'} = 1;
    }
    $signal = 'hup';
}


############################################################
#  DoFile
############################################################
#  Handles a file received and files in the queue directory. 
#  This will read the file, separate the header and the body 
#  of the message and call the adequate function wether we 
#  have received a command or a message to be redistributed 
#  to a list.
#  
# IN : -$file (+): the file to handle
#      
# OUT : $status
#     | undef
#
##############################################################
sub DoFile {
    my ($file) = @_;
    &do_log('debug', 'DoFile(%s)', $file);
    
    my ($listname, $robot);
    my $status;
    
    my $message = new Message($file);
    unless (defined $message) {
	&do_log('err', 'Unable to create Message object %s', $file);
	return undef;
    }
    
    my $msg = $message->{'msg'};
    my $hdr = $msg->head;
    my $rcpt = $message->{'rcpt'};
    

    ## get listname & robot
    ($listname, $robot) = split(/\@/,$rcpt);
    
    $robot = lc($robot);
    $listname = lc($listname);
    $robot ||= &Conf::get_robot_conf($robot,'host');
    
    my $type;
    my $list_check_regexp = &Conf::get_robot_conf($robot,'list_check_regexp');
    if ($listname =~ /^(\S+)-($list_check_regexp)$/) {
	($listname, $type) = ($1, $2);
    }

    # message prepared by wwsympa and distributed by sympa # dual
    if ( $hdr->get('X-Sympa-Checksum')) {
	return (&DoSendMessage ($msg,$robot)) ;
    }
    
    # setting log_level using conf unless it is set by calling option
    unless ($main::options{'log_level'}) {
	$log_level =  &Conf::get_robot_conf($robot,'log_level');
	&do_log('debug', "Setting log level with $robot configuration (or sympa.conf) : $log_level"); 
    }
    
    ## Ignoring messages with no sender
    my $sender = $message->{'sender'};
    unless ($sender) {
	&do_log('err', 'No From found in message, skipping.');
	return undef;
    }

    ## Strip of the initial X-Sympa-To field
    $hdr->delete('X-Sympa-To');
    
    ## Loop prevention
    my $conf_email = &Conf::get_robot_conf($robot, 'email');
    my $conf_host = &Conf::get_robot_conf($robot, 'host');
    if ($sender =~ /^(mailer-daemon|sympa|listserv|mailman|majordomo|smartlist|$conf_email)(\@|$)/mio) {
	&do_log('notice','Ignoring message which would cause a loop, sent by %s', $sender);
	return undef;
    }
	
    ## Initialize command report
    &report::init_report_cmd();
	
    ## Q- and B-decode subject
    my $subject_field = $message->{'decoded_subject'};
        
    my ($list, $host, $name);   
    if ($listname =~ /^(sympa|$Conf{'listmaster_email'}|$conf_email)(\@$conf_host)?$/i) {
	$host = $conf_host;
	$name = $listname;
    }else {
	$list = new List ($listname, $robot);
	unless (defined $list) {
	    &do_log('err', 'sympa::DoFile() : list %s no existing',$listname);
	    &report::global_report_cmd('user','no_existing_list',{'listname'=>$listname},$sender,$robot,1);
	    return undef;
	}
	$host = $list->{'admin'}{'host'};
	$name = $list->{'name'};
	# setting log_level using list config unless it is set by calling option
	unless ($main::options{'log_level'}) {
	    $log_level = $list->{'log_level'};
	    &do_log('debug', "Setting log level with list configuration : $log_level"); 
	}
    }
    
    ## Loop prevention
    my $loop;
    foreach $loop ($hdr->get('X-Loop')) {
	chomp $loop;
	&do_log('debug2','X-Loop: %s', $loop);
	#foreach my $l (split(/[\s,]+/, lc($loop))) {
	    if ($loop eq lc($list->get_list_address())) {
		do_log('notice', "Ignoring message which would cause a loop (X-Loop: $loop)");
		return undef;
	    }
	#}
    }
    
    ## Content-Identifier: Auto-replied is generated by some non standard 
    ## X400 mailer
    if ($hdr->get('Content-Identifier') =~ /Auto-replied/i) {
	do_log('notice', "Ignoring message which would cause a loop (Content-Identifier: Auto-replied)");
	return undef;
    }elsif ($hdr->get('X400-Content-Identifier') =~ /Auto Reply to/i) {
	do_log('notice', "Ignoring message which would cause a loop (X400-Content-Identifier: Auto Reply to)");
	return undef;
    }

    ## encrypted message
    if ($message->{'smime_crypted'}) {
	$is_crypted = 'smime_crypted';
    }else {
	$is_crypted = 'not_crypted';
    }

    ## S/MIME signed messages
    if ($message->{'smime_signed'}) {
	$is_signed = {'subject' => $message->{'smime_subject'},
		      'body' => 'smime'};
    }else {
	undef $is_signed;
    }
	
    #  anti-virus
    my $rc= &tools::virus_infected($message->{'msg'}, $message->{'filename'});
    if ($rc) {
	if ( &Conf::get_robot_conf($robot,'antivirus_notify') eq 'sender') {
	    unless (&List::send_global_file('your_infected_msg', $sender, $robot, {'virus_name' => $rc,
										   'recipient' => $list->get_list_address(),
										   'lang' => $Language::default_lang})) {
		&do_log('notice',"Unable to send template 'your infected_msg' to $sender");
	    }
	}
	&do_log('notice', "Message for %s from %s ignored, virus %s found", $list->get_list_address(), $sender, $rc);
	return undef;

    }elsif (! defined($rc)) {
 	unless (&List::send_notify_to_listmaster('antivirus_failed',$robot,["Could not scan $file; The message has been saved as BAD."])) {
 	    &do_log('notice',"Unable to send notify 'antivirus_failed' to listmaster");
 	}

	return undef;
    }
  
    if ($main::daemon_usage eq 'message') {
	if (($rcpt =~ /^$Conf{'listmaster_email'}(\@(\S+))?$/) || ($rcpt =~ /^(sympa|$conf_email)(\@\S+)?$/i) || ($type =~ /^(subscribe|unsubscribe)$/o) || ($type =~ /^(request|owner|editor)$/o)) {
	    &do_log('err','internal serveur error : distribution daemon should never proceed with command');
	    &report::global_report_cmd('intern','Distribution daemon proceed with command',{},$sender,$robot,1);
	    return undef;
	} 
    }
    if ($rcpt =~ /^listmaster(\@(\S+))?$/) {
	$status = &DoForward('sympa', 'listmaster', $robot, $msg);

	## Mail adressed to the robot and mail 
	## to <list>-subscribe or <list>-unsubscribe are commands
    }elsif (($rcpt =~ /^(sympa|$conf_email)(\@\S+)?$/i) || ($type =~ /^(subscribe|unsubscribe)$/o)) {
	$status = &DoCommand($rcpt, $robot, $message);
	
	## forward mails to <list>-request <list>-owner etc
    }elsif ($type =~ /^(request|owner|editor)$/o) {
	
	## Simulate Smartlist behaviour with command in subject
	if (($type eq 'request') and ($subject_field =~ /^\s*(subscribe|unsubscribe)(\s*$listname)?\s*$/i) ) {
	    my $command = $1;
	    
	    $status = &DoCommand("$listname-$command", $robot, $message);
	}else {
	    $status = &DoForward($listname, $type, $robot, $msg);
	}         
    }else {	
	$status =  &DoMessage($rcpt, $message, $robot);
    }
    

    ## Mail back the result.
    if (&report::is_there_any_report_cmd()) {

	## Loop prevention

	## Count reports sent to $sender
	$loop_info{$sender}{'count'}++;
	
	## Sampling delay 
	if ((time - $loop_info{$sender}{'date_init'}) < &Conf::get_robot_conf($robot, 'loop_command_sampling_delay')) {

	    ## Notify listmaster of first rejection
	    if ($loop_info{$sender}{'count'} ==  &Conf::get_robot_conf($robot, 'loop_command_max')) {
		## Notify listmaster
		unless (&List::send_notify_to_listmaster('loop_command',  &Conf::get_robot_conf($robot, 'domain'),
							 {'msg' => $file})) {
		    &do_log('notice',"Unable to send notify 'loop_command' to listmaster");
		}
	    }
	    
	    ## Too many reports sent => message skipped !!
	    if ($loop_info{$sender}{'count'} >=  &Conf::get_robot_conf($robot, 'loop_command_max')) {
		&do_log('notice', 'Ignoring message which would cause a loop, %d messages sent to %s', $loop_info{$sender}{'count'}, $sender);
		
		return undef;
	    }
	}else {
	    ## Sampling delay is over, reinit
	    $loop_info{$sender}{'date_init'} = time;

	    ## We apply Decrease factor if a loop occured
	    $loop_info{$sender}{'count'} *=  &Conf::get_robot_conf($robot,'loop_command_decrease_factor');
	}

	## Send the reply message
	&report::send_report_cmd($sender,$robot);

    }
    
    return $status;
}

############################################################
#  DoSendMessage
############################################################
#  Send a message pushed in spool by another process. 
#  
# IN : -$msg (+): ref(MIME::Entity)
#      -$robot (+) :robot
#      
# OUT : 1 
#     | undef
#
############################################################## 
sub DoSendMessage {
    my $msg = shift;
    my $robot = shift;
    &do_log('debug', 'DoSendMessage()');

    my $hdr = $msg->head;
    
    my ($chksum, $rcpt, $from) = ($hdr->get('X-Sympa-Checksum'), $hdr->get('X-Sympa-To'), $hdr->get('X-Sympa-From'));
    chomp $rcpt; chomp $chksum; chomp $from;

    do_log('info', "Processing web message for %s", $rcpt);
    
    my $string = $msg->as_string;
    my $msg_id = $hdr->get('Message-ID');
    my $sender = $hdr->get('From');

    unless ($chksum eq &tools::sympa_checksum($rcpt)) {
	&do_log('err', 'sympa::DoSendMessage(): message ignored because incorrect checksum');
	&report::reject_report_msg('intern','Message ignored because incorrect checksum',$sender,
			  {'msg_id' => $msg_id},
			  $robot,$string,'');
	return undef ;
    }

    $hdr->delete('X-Sympa-Checksum');
    $hdr->delete('X-Sympa-To');
    $hdr->delete('X-Sympa-From');
    
    ## Multiple recepients
    my @rcpts = split /,/,$rcpt;
   
    unless (&mail::mail_forward($msg,$from,\@rcpts,$robot)) {
	&do_log('err',"sympa::DoSendMessage(): Impossible to forward mail from $from");
	&report::reject_report_msg('intern','Impossible to forward a message pushed in spool by another process than sympa.pl.',$sender,
			  {'msg_id' => $msg_id},$robot,$string,'');
	return undef;
    }

    &do_log('info', "Message for %s sent", $rcpt);

    return 1;
}

############################################################
#  DoForward                             
############################################################
#  Handles a message sent to [list]-editor : the list editor, 
#  [list]-request : the list owner or the listmaster. 
#  Message is forwarded according to $function
#  
# IN : -$name : list name (+) if ($function <> 'listmaster')
#      -$function (+): 'listmaster'|'request'|'editor'
#      -$robot (+): robot
#      -$msg (+): ref(MIME::Entity)
#
# OUT : 1 
#     | undef
#
############################################################
sub DoForward {
    my($name, $function, $robot, $msg) = @_;
    &do_log('debug', 'DoForward(%s, %s, %s, %s)', $name, $function);

    my $hdr = $msg->head;
    my $messageid = $hdr->get('Message-Id');
    my $msg_string = $msg->as_string;
    ##  Search for the list
    my ($list, $admin, $host, $recepient, $priority);

    if ($function eq 'listmaster') {
	$recepient=$Conf{'listmaster_email'};
	$host = &Conf::get_robot_conf($robot, 'host');
	$priority = 0;
    }else {
	unless ($list = new List ($name, $robot)) {
	    &do_log('notice', "Message for %s-%s ignored, unknown list %s",$name, $function, $name );
	    my $sender = chomp($hdr->get('From'));
	    my $sympa_email = &Conf::get_robot_conf($robot, 'sympa');
	    unless (&List::send_global_file('list_unknown', $sender, $robot,
					    {'list' => $name,
					     'date' => &POSIX::strftime("%d %b %Y  %H:%M", localtime(time)),
					     'boundary' => $sympa_email.time,
					     'header' => $hdr->as_string()
					     })) {
		&do_log('notice',"Unable to send template 'list_unknown' to $sender");
	    }
	    return undef;
	}
	
	$admin = $list->{'admin'};
	$host = $admin->{'host'};
        $recepient="$name-$function";
	$priority = $admin->{'priority'};
    }

    my @rcpt;
    
    &do_log('info', "Processing message for %s with priority %s, %s", $recepient, $priority, $messageid );
    
    $hdr->add('X-Loop', "$name-$function\@$host");
    $hdr->delete('X-Sympa-To:');

    if ($function eq "listmaster") {
	my $listmasters = &Conf::get_robot_conf($robot, 'listmasters');
	@rcpt = @{$listmasters};
	&do_log('notice', 'Warning : no listmaster defined in sympa.conf') 
	    unless (@rcpt);
	
    }elsif ($function eq "request") {
	@rcpt = $list->get_owners_email();

	&do_log('notice', 'Warning : no owner defined or all of them use nomail option in list %s', $name ) 
	    unless (@rcpt);

    }elsif ($function eq "editor") {
	@rcpt = $list->get_editors_email();

	&do_log('notice', 'Warning : no owner and editor defined or all of them use nomail option in list %s', $name ) 
	    unless (@rcpt);
    }
    
    if ($#rcpt < 0) {
	&do_log('err', "sympa::DoForward(): Message for %s-%s ignored, %s undefined in list %s", $name, $function, $function, $name);
	my $string = sprintf 'Impossible to forward a message to %s-%s : undefined in this list',$name,$function;
	my $sender = $hdr->get('From');
	&report::reject_report_msg('intern',$string,$sender,
			  {'msg_id' => $messageid,
			   'entry' => 'forward',
			   'function' => $function}
			  ,$robot,$msg_string,$list);
	return undef;
   }
   
    my $rc;
    my $msg_copy = $msg->dup;

    unless (&mail::mail_forward($msg,&Conf::get_robot_conf($robot, 'request'),\@rcpt,$robot)) {
	&do_log('err',"Impossible to forward mail for $name-$function  ");
	my $string = sprintf 'Impossible to forward a message for %s-%s',$name,$function;
	my $sender = $hdr->get('From');
	&report::reject_report_msg('intern',$string,$sender,
			  {'msg_id' => $messageid,
			   'entry' => 'forward',
			   'function' => $function}
			  ,$robot,$msg_string,$list);
	return undef;
    }

    return 1;
}

####################################################
#  DoMessage                             
####################################################
#  Handles a message sent to a list. (Those that can 
#  make loop and those containing a command are 
#  rejected)
#  
# IN : -$which (+): 'listname@hostname' - concerned list
#      -$message (+): ref(Message) - sent message
#      -$robot (+): robot
#
# OUT : 1 if ok (in order to remove the file from the queue)
#     | undef
#
####################################################
sub DoMessage{
    my($which, $message, $robot) = @_;
    &do_log('debug', 'DoMessage(%s, %s, %s, msg from %s, %s, %s,%s)', $which, $message->{'msg'}, $robot, $message->{'sender'}, $message->{'size'}, $message->{'msg_as_string'}, $message->{'smime_crypted'});
    
    ## List and host.
    my($listname, $host) = split(/[@\s]+/, $which);
    
    my $hdr = $message->{'msg'}->head;
    
    my $messageid = $hdr->get('Message-Id');
    my $msg_string = $message->{'msg'}->as_string;
    
    my $sender = $message->{'sender'};
    
    ## Search for the list
    my $list = new List ($listname, $robot);
    
    ## List unknown
    unless ($list) {
	&do_log('notice', 'Unknown list %s', $listname);
	my $sympa_email = &Conf::get_robot_conf($robot, 'sympa');
	
	unless (&List::send_global_file('list_unknown', $sender, $robot,
					{'list' => $which,
					 'date' => &POSIX::strftime("%d %b %Y  %H:%M", localtime(time)),
					 'boundary' => $sympa_email.time,
					 'header' => $hdr->as_string()
					 })) {
	    &do_log('notice',"Unable to send template 'list_unknown' to $sender");
	}
	return undef;
    }
    
    ($listname, $host) = ($list->{'name'}, $list->{'admin'}{'host'});
    
    my $start_time = time;
    
    &Language::SetLang($list->{'admin'}{'lang'});
    
    ## Now check if the sender is an authorized address.
    
    &do_log('info', "Processing message for %s with priority %s, %s", $listname,$list->{'admin'}{'priority'}, $messageid );
    
    my $conf_email = &Conf::get_robot_conf($robot, 'sympa');
    if ($sender =~ /^(mailer-daemon|sympa|listserv|majordomo|smartlist|mailman|$conf_email)(\@|$)/mio) {
	do_log('notice', 'Ignoring message which would cause a loop');
	return undef;
    }
	
    if ($msgid_table{$listname}{$messageid}) {
	&do_log('notice', 'Found known Message-ID, ignoring message which would cause a loop');
	return undef;
    }
	
    # Reject messages with commands
    if ( &Conf::get_robot_conf($robot,'misaddressed_commands') =~ /reject/i) {
	## Check the message for commands and catch them.
	if (&tools::checkcommand($message->{'msg'}, $sender, $robot)) {
	    &do_log('info', 'sympa::DoMessage(): Found command in message, ignoring message');
	    &report::reject_report_msg('user','routing_error',$sender,{},$robot,$msg_string,$list);
	    return undef;
	}
    }
	
    my $admin = $list->{'admin'};
    unless ($admin) {
	&do_log('err', 'sympa::DoMessage(): list config is undefined');
	&report::reject_report_msg('intern','',$sender,{'msg'=>$messageid},$robot,$msg_string,$list);
	return undef;
  }
    
    my $customheader = $admin->{'custom_header'};
#    $host = $admin->{'host'} if ($admin->{'host'});

    ## Check if the message is a return receipt
    if ($hdr->get('multipart/report')) {
	&do_log('notice', 'Message for %s from %s ignored because it is a report', $listname, $sender);
	return undef;
    }
    
    ## Check if the message is too large
    # my $max_size = $list->get_max_size() ||  &Conf::get_robot_conf($robot,'max_size');
    my $max_size = $list->get_max_size();

    if ($max_size && $message->{'size'} > $max_size) {
	&do_log('info', 'sympa::DoMessage(): Message for %s from %s rejected because too large (%d > %d)', $listname, $sender, $message->{'size'}, $max_size);
	&report::reject_report_msg('user','message_too_large',$sender,{},$robot,$msg_string,$list);
	return undef;
   }
    
    my $rc;
	
    my $context =  {'sender' => $sender,
		    'message' => $message };
	
    ## list msg topic	
    if ($list->is_there_msg_topic()) {

	my $info_msg_topic = $list->load_msg_topic_file($messageid,$robot);

	# is msg already tagged ?	
	if (ref($info_msg_topic) eq "HASH") { 
	    if ($info_msg_topic->{'method'} eq "sender") {
		$context->{'topic_sender'} =  $info_msg_topic->{'topic'};
		
	    }elsif ($info_msg_topic->{'method'} eq "editor") {
		$context->{'topic_editor'} =  $info_msg_topic->{'topic'};
	    
	    }elsif ($info_msg_topic->{'method'} eq "auto") {
		$context->{'topic_auto'} =  $info_msg_topic->{'topic'};
	    }

	# not already tagged   
	} else {
	    $context->{'topic_auto'} = $list->automatic_tag($message->{'msg'},$robot);
	}

	$context->{'topic'} = $context->{'topic_auto'} || $context->{'topic_sender'} || $context->{'topic_editor'};
	$context->{'topic_needed'} = (!$context->{'topic'} && $list->is_msg_topic_tagging_required());
    }
	
    ## Call scenarii : auth_method MD5 do not have any sense in send
    ## scenarii because auth is perfom by distribute or reject command.
    
    my $action;
    my $result;	
    if ($is_signed->{'body'}) {
	$result = $list->check_list_authz('send', 'smime',$context);
	$action = $result->{'action'} if (ref($result) eq 'HASH');
    }else{
	$result = $list->check_list_authz('send', 'smtp',$context);
	$action = $result->{'action'} if (ref($result) eq 'HASH');
    } 

    unless (defined $action) {
	&do_log('err', 'sympa::DoMessage(): message (%s) ignored because unable to evaluate scenario "send" for list %s',$messageid,$listname);
	&report::reject_report_msg('intern','Message ignored because scenario "send" cannot be evaluated',$sender,
			  {'msg_id' => $messageid},
			  $robot,$msg_string,$list);
	return undef ;
    }
	

    ## message topic context	
    if (($action =~ /^do_it/) && ($context->{'topic_needed'})) {
	$action = "editorkey";
    }

    if (($action =~ /^do_it/) || ($main::daemon_usage eq 'message')) {


	if (($main::daemon_usage eq  'message') || ($main::daemon_usage eq  'command_and_message')) {
	    my $numsmtp = $list->distribute_msg($message);
	    
	    ## Keep track of known message IDs...if any
	    $msgid_table{$listname}{$messageid}++ if ($messageid);
	    
	    unless (defined($numsmtp)) {
		&do_log('err','sympa::DoMessage(): Unable to send message to list %s', $listname);
		&report::reject_report_msg('intern','',$sender,{'msg_id' => $messageid},$robot,$msg_string,$list);
		return undef;
	    }
	    &do_log('info', 'Message for %s from %s accepted (%d seconds, %d sessions, %d subscribers), message-id=%s, size=%d', $listname, $sender, $list->get_total(), time - $start_time, $numsmtp, $messageid, $message->{'size'});
	    return 1;

	}else{   
	    # this message is to be distributed but this daemon is dedicated to commands -> move it to distribution spool
	    unless ($list->move_message($message->{'filename'})) {
		&do_log('err','sympa::DoMessage(): Unable to move in spool for distribution message to list %s (daemon_usage = command)', $listname);
		&report::reject_report_msg('intern','',$sender,{'msg_id' => $messageid},$robot,$msg_string,$list);
		return undef;
	    }
	    &do_log('info', 'Message for %s from %s moved in spool %s for distribution message-id=%s', $listname, $sender, $Conf{'queuedistribute'},$messageid);
	    return 1;
	}
	
    }elsif($action =~ /^request_auth/){
    	my $key = $list->send_auth($message);

	unless (defined $key) {
	    &do_log('err','sympa::DoMessage(): Calling to send_auth function failed for user %s in list %s', $sender, $list->{'name'});
	    &report::reject_report_msg('intern','The request authentication sending failed',$sender,{'msg_id' => $messageid},$robot,$msg_string,$list);
	    return undef
	}
	&do_log('notice', 'Message for %s from %s kept for authentication with key %s', $listname, $sender, $key);
	return 1;
    }elsif($action =~ /^editorkey(\s?,\s?(quiet))?/){
	my $key = $list->send_to_editor('md5',$message);

	unless (defined $key) {
	    &do_log('err','sympa::DoMessage(): Calling to send_to_editor() function failed for user %s in list %s', $sender, $list->{'name'});
	    &report::reject_report_msg('intern','The request moderation sending to moderator failed.',$sender,{'msg_id' => $messageid},$robot,$msg_string,$list);
	    return undef
	}

	&do_log('info', 'Key %s for list %s from %s sent to editors, %s', $key, $listname, $sender, $message->{'filename'});
	
	unless ($2 eq 'quiet') {
	    unless (&report::notice_report_msg('moderating_message',$sender,{},$robot,$list)) {
		&do_log('notice',"sympa::DoMessage(): Unable to send template 'message_report', entry 'moderating_message' to $sender");
	    }
	}
	return 1;
    }elsif($action =~ /^editor(\s?,\s?(quiet))?/){
	my $key = $list->send_to_editor('smtp', $message);

	unless (defined $key) {
	    &do_log('err','sympa::DoMessage(): Calling to send_to_editor() function failed for user %s in list %s', $sender, $list->{'name'});
	    &report::reject_report_msg('intern','The request moderation sending to moderator failed.',$sender,{'msg_id' => $messageid},$robot,$msg_string,$list);
	    return undef
	}

	&do_log('info', 'Message for %s from %s sent to editors', $listname, $sender);
	
	unless ($2 eq 'quiet') {
	    unless (&report::notice_report_msg('moderating_message',$sender,{},$robot,$list)) {
		&do_log('notice',"sympa::DoMessage(): Unable to send template 'message_report', type 'success', entry 'moderating_message' to $sender");
	    }
	}
	return 1;
    }elsif($action =~ /^reject(,(quiet))?/) {

	&do_log('notice', 'Message for %s from %s rejected(%s) because sender not allowed', $listname, $sender, $result->{'tt2'});
	unless ($2 eq 'quiet') {
	    if (defined $result->{'tt2'}) {
		unless ($list->send_file($result->{'tt2'}, $sender, $robot, {})) {
		    &do_log('notice',"sympa::DoMessage(): Unable to send template '$result->{'tt2'}' to $sender");
		}
	    }else {
		unless (&report::reject_report_msg('auth',$result->{'reason'},$sender,{},$robot,$msg_string,$list)) {
		    &do_log('notice',"sympa::DoMessage(): Unable to send template 'message_report', type 'auth' to $sender");
		}
	    }
	}
	return undef;
    }else {
	&do_log('err','sympa::DoMessage(): unknown action %s returned by the scenario "send"', $action);
	&report::reject_report_msg('intern','Unknown action returned by the scenario "send"',$sender,{'msg_id' => $messageid},$robot,$msg_string,$list);
	return undef;
    }
}

############################################################
#  DoCommand
############################################################
#  Handles a command sent to the list manager.
#  
# IN : -$rcpt : recepient | <listname>-<subscribe|unsubscribe> 
#      -$robot (+): robot
#      -$message : ref(Message) with :
#        ->msg (+): ref(MIME::Entity) : message containing command
#        ->filename (+): file containing message
#      
# OUT : $success
#     | undef
#
############################################################## 
sub DoCommand {
    my($rcpt, $robot, $message) = @_;
    my $msg = $message->{'msg'};
    my $file = $message->{'filename'};
    &do_log('debug', 'DoCommand(%s %s %s %s) ', $rcpt, $robot, $msg, $file);
    
    ## boolean
    my $cmd_found = 0;
    
    ## Now check if the sender is an authorized address.
    my $hdr = $msg->head;
    
    ## Decode headers
    #$hdr->decode();
    
    my $messageid = $hdr->get('Message-Id');
    my ($success, $status);
    
    &do_log('debug', "Processing command with priority %s, %s", $Conf{'sympa_priority'}, $messageid );
    
    my $sender = $message->{'sender'};

    ## Detect loops
    if ($msgid_table{$robot}{$messageid}) {
	&do_log('notice', 'Found known Message-ID, ignoring command which would cause a loop');
	return undef;
    }## Clean old files from spool
    
    ## Keep track of known message IDs...if any
    $msgid_table{$robot}{$messageid}++
	if ($messageid);

    ## If X-Sympa-To = <listname>-<subscribe|unsubscribe> parse as a unique command
    if ($rcpt =~ /^(\S+)-(subscribe|unsubscribe)(\@(\S+))?$/o) {
	&do_log('debug',"processing message for $1-$2");
	&Commands::parse($sender,$robot,"$2 $1");
	return 1; 
    }
    
    ## Process the Subject of the message
    ## Search and process a command in the Subject field
    my $subject_field = $message->{'decoded_subject'};
    $subject_field =~ s/\n//mg; ## multiline subjects
    $subject_field =~ s/^\s*(Re:)?\s*(.*)\s*$/$2/i;

    $success ||= &Commands::parse($sender, $robot, $subject_field, $is_signed->{'subject'}) ;

    unless ($success eq 'unknown_cmd') {
	$cmd_found = 1;
    }

    ## Make multipart singlepart
    if ($msg->is_multipart()) {
	my $status = &tools::as_singlepart($msg, 'text/plain');

	unless (defined $status) {
	    &do_log('err', 'Could not change multipart to singlepart');
	    &report::global_report_cmd('user','error_content_type',{});
	    return undef;
	}

	if ($status) {
	    &do_log('notice', 'Multipart message changed to singlepart');
	}
    }

    my $i;
    my $size;

    ## Process the body of the message
    ## unless subject contained commands or message has no body
    if ( (!$cmd_found) && (defined $msg->bodyhandle)) { 

    ## check Content-type
    my $mime = $hdr->get('Mime-Version') ;
    my $content_type = $hdr->get('Content-type');
    my $transfert_encoding = $hdr->get('Content-transfer-encoding');
    unless (($content_type =~ /text/i and !$mime)
	    or !($content_type) 
	    or ($content_type =~ /text\/plain/i)) {
	&do_log('notice', "Ignoring message body not in text/plain, Content-type: %s", $content_type);
	&report::global_report_cmd('user','error_content_type',{});
	return $success; 
    }
    
    my @body = $msg->bodyhandle->as_lines();
    foreach $i (@body) {
	if ($transfert_encoding =~ /quoted-printable/i) {
	    $i = MIME::QuotedPrint::decode($i);
	}
	
	$i =~ s/^\s*>?\s*(.*)\s*$/$1/g;
	next if ($i =~ /^$/); ## skip empty lines
	next if ($i =~ /^\s*\#/) ;
    
	&do_log('debug2',"is_signed->body $is_signed->{'body'}");
	
	$status = &Commands::parse($sender, $robot, $i, $is_signed->{'body'});
	$cmd_found = 1; # if problem no_cmd_understood is sent here
	if ($status eq 'unknown_cmd') {
	    &do_log('notice', "Unknown command found :%s", $i);
	    &report::reject_report_cmd('user','not_understood',{},$i);
  	    last;
	}
	
	    if ($i =~ /^(qui|quit|end|stop|-)/io) {
		last;
	    }
	    
	    $success ||= $status;
	}
    }

    ## No command found
    unless ($cmd_found == 1) {
	&do_log('info', "No command found in message");
	&report::global_report_cmd('user','no_cmd_found',{});
	return undef;
    }
    
    return $success;
}

############################################################
#  SendDigest
############################################################
#  Read the queuedigest and send old digests to the subscribers 
#  with the digest option.
#  
# IN : -
#      
# OUT : -
#     | undef
#
############################################################## 
sub SendDigest{
    &do_log('debug', 'SendDigest()');

    if (!opendir(DIR, $Conf{'queuedigest'})) {
	fatal_err(gettext("Unable to access directory %s : %m"), $Conf{'queuedigest'}); ## No return.
    }
    my @dfile =( sort grep (!/^\./,readdir(DIR)));
    closedir(DIR);


    foreach my $listaddress (@dfile){

 	my $filename = $Conf{'queuedigest'}.'/'.$listaddress;
	
 	my ($listname, $listrobot) = split /\@/, $listaddress;
 	my $list = new List ($listname, $listrobot);
	unless ($list) {
	    &do_log('info', 'Unknown list, deleting digest file %s', $filename);
	    unlink $filename;
	    return undef;
	}

	&Language::SetLang($list->{'admin'}{'lang'});

	if ($list->get_nextdigest()){
	    ## Blindly send the message to all users.
	    do_log('info', "Sending digest to list %s", $listaddress);
	    my $start_time = time;
	    $list->send_msg_digest();

	    unlink($filename);
	    do_log('info', 'Digest of the list %s sent (%d seconds)', $listname,time - $start_time);
	}
    }
}


############################################################
#  CleanSpool
############################################################
#  Cleans files older than $clean_delay from spool $spool_dir
#  
# IN : -$spool_dir (+): the spool directory
#      -$clean_delay (+): delay in days 
#
# OUT : 1
#
############################################################## 
sub CleanSpool {
    my ($spool_dir, $clean_delay) = @_;
    &do_log('debug', 'CleanSpool(%s,%s)', $spool_dir, $clean_delay);

    unless (opendir(DIR, $spool_dir)) {
	&do_log('err', "Unable to open '%s' spool : %s", $spool_dir, $!);
	return undef;
    }

    my @qfile = sort grep (!/^\.+$/,readdir(DIR));
    closedir DIR;
    
    my ($curlist,$moddelay);
    foreach my $f (sort @qfile) {

	if ((stat "$spool_dir/$f")[9] < (time - $clean_delay * 60 * 60 * 24)) {
	    if (-f "$spool_dir/$f") {
		unlink ("$spool_dir/$f") ;
		&do_log('notice', 'Deleting old file %s', "$spool_dir/$f");
	    }elsif (-d "$spool_dir/$f") {
		unless (opendir(DIR, "$spool_dir/$f")) {
		    &do_log('err', 'Cannot open directory %s : %s', "$spool_dir/$f", $!);
		    next;
		}
		my @files = sort grep (!/^\./,readdir(DIR));
		foreach my $file (@files) {
		    unlink ("$spool_dir/$f/$file");
		}	
		closedir DIR;
		
		rmdir ("$spool_dir/$f") ;
		&do_log('notice', 'Deleting old directory %s', "$spool_dir/$f");
	    }
	}
    }

    return 1;
}












1;


