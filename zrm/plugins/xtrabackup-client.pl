#!/usr/bin/perl

# This is the plugin to use to copy files from a remote machine
# that has the corresponding client installed.
# This uses sockets to copy from/to a remote machine.
#
# If the first command line parameter is --mysqlhotcopy then the plug will
# execute mysqlhotcopy on the remote machine and then copy the data over.
# Else it will just copy the requested data either from or to the given machine.
#
# If the first parameter to the plugin is --mysqlhotcopy then
# remaining Command line parameters that the plugin expects are
# [--host=<name>]
# [--user=<mysql username>]
# [--password=<password>"]
# [--port=<#>]
# [--socket=<socket file>]
# [--quiet]
# db_name[./table_regex/]
# directory
# Else the command line parameters that this plugin exects are
# --source-host <name>,
# --source-file <filename>,
# --destination-host <name>,
# --destination-directory <destination file>
################################################################################

# ###########################################################################
# ProcessLog package FSL_VERSION
# ###########################################################################
# ###########################################################################
# End ProcessLog package
# ###########################################################################

# ###########################################################################
# IniFile package FSL_VERSION
# ###########################################################################
# ###########################################################################
# End IniFile package
# ###########################################################################

package XtraBackupClient;

use strict;
use warnings FATAL => 'all';
use Socket;
use File::Temp qw/ :POSIX /;
use Getopt::Long;
use File::Basename;
use File::Spec::Functions;
use Data::Dumper;
use ProcessLog;
use IniFile;

my $TAR = "tar";
my $TAR_WRITE_OPTIONS = "";
my $TAR_READ_OPTIONS = "";
my $CP="cp -pr";

my $VERSION = "0.75.1";
my $REMOTE_PORT=25300;

my $srcHost = "localhost";
my $destHost = "localhost";
my $destDir;
my $srcFile;
my $action;
my $params;
my $host;
my @snapshotParamList;
my $snapshotConfString;
my %config;

$SIG{'PIPE'} = sub { $::PL->end; die "Pipe broke"; };
$SIG{'TERM'} = sub { close SOCK; $::PL->end; die "TERM broke\n"; };

$config{'socket-copy-logfile'} = '/var/log/mysql-zrm/socket-copy.log';
$config{'socket-copy-email'} = undef;
$config{'tar-force-ownership'} = 1;
$config{'apply-xtrabackup-log'} = 0;



# Reads a key=value block from the incoming stream.
# The format of a key=value block is as follows:
# <number of lines(N) to follow>\n
# <key=value\n>{N}
#
# N, is allowed to be 0.
# This function returns a hashref of the read key=value pairs.
#
sub readKvBlock {
  my $fh = shift;
  my (%kv, $i, $N) = ((), 0, 0);
  chomp($N = <$fh>);
  checkIfTainted($N);
  if($N !~ /^\d+$/) {
    printAndDie("Bad input: $_");
  }
  for($i = 0; $i < $N; $i++) {
    chomp($_ = <$fh>);
    checkIfTainted($_);
    my ($k, $v) = split(/=/, $_, 2);
    $kv{$k} = $v;
  }
  return \%kv;
}

# Given a realhash, this returns a string in the format:
# <N>\n
# <key>=<value>\n{N}
#
# Where 'N' is the number of keys in the hash.
#
sub makeKvBlock {
  my %Kv = @_;
  my $out = scalar(keys %Kv). "\n";
  foreach my $k (keys %Kv) {
    $out .= "$k=$Kv{$k}\n";
  }
  return $out;
}

sub printAndDie {
  $::PL->e(@_);
  $::PL->end;
  die("ERROR: @_");
}

sub my_exit {
  $::PL->end;
  exit($_[0]);
}

# Parses the command line for all of the copy parameters
sub getCopyParameters {
  my %opt;
  my $ret = GetOptions( \%opt,
    "source-host=s",
    "source-file=s",
    "create-link",
    "destination-host=s",
    "destination-directory=s" );

  unless( $ret ){
    die( "Invalid parameters" );
  }

  if( !$opt{"source-file"} ){
    die( "No source file defined" );
  }else{
    $srcFile=$opt{"source-file"};
  }

  if( !$opt{"destination-directory"} ){
    die( "No destination file defined" );
  }else{
    $destDir=$opt{"destination-directory"};
  }

  if( $opt{"source-host"} ){
    $srcHost = $opt{"source-host"};
  }

  if( $opt{"destination-host"} &&
    $opt{"destination-host"} ne "localhost" ){
    $destHost = $opt{"destination-host"};
  }

  if( $srcHost eq "localhost" && $destHost eq "localhost" ){
    doLocalTar();
    my_exit(0);
  }

  if( defined $opt{"create-link"} ){
    $action = "create-link";
    $params = $srcFile;
    $host = $destHost;
  }else{

    if( $srcHost ne "localhost" && $destHost ne "localhost" ){
      $action = "copy between";
      $host = $srcHost;
      my $d = $destHost;
      if( $destHost eq $srcHost ){
        $d = "localhost";
      }
      $params = "--source-file '$srcFile' --destination-dir $destDir --source-host localhost --destination-host $d";
    }else{
      if( $srcHost ne "localhost" ){
        $action = "copy from";
        $params = $srcFile;
        $host = $srcHost;
      }else{
        $action = "copy to";
        $params = $destDir;
        $host = $destHost;
      }
    }
  }
  $::PL->m("socket-copy:\taction:$action\n\tsrcHost:$srcHost\n\tparams:$params\n\tdestHost:$destHost\n\tdestDir:$destDir");
}

sub doLocalTar {
  my $cmd;
  my $tarCmd = $^O eq "linux" ? "$TAR --same-owner -psC " : "$TAR -pC";

  if( $config{'tar-force-ownership'} == 0 ) {
    if($^O eq 'linux') {
      $tarCmd = "$TAR --no-same-owner --no-same-permissions -sC";
    }
    elsif($^O eq 'freebsd') {
      $tarCmd = "$TAR -C";
    }
  }

  my $srcDir = dirname( $srcFile );
  my $srcFile = basename( $srcFile );

  my $d = tmpnam();

  my $fileList = $srcFile;
  my $lsCmd = "";
  if( $srcFile =~ /\*/){
    $lsCmd = "cd $srcDir; ls -1 $srcFile > $d 2>/dev/null;";
    $fileList = " -T $d";
  }

  my $srcCmd = "$lsCmd $tarCmd $srcDir -h -c $fileList";
  my $destCmd = "$tarCmd $destDir -x";
  $cmd = "$srcCmd|$destCmd";

  $::PL->m("local-tar:\n\t$cmd");

  my $r = system( $cmd );
  if( $lsCmd ne "" ){
    unlink $d;
  }
  if( $r > 0 ){
    printAndDie("Could not copy data $!");
  }
}

sub getSnapshotParams {
  my $y = shift @ARGV;
  my %opt;
  GetOptions( \%opt,
    "host=s",
    "snapshot-parameters=s" );
  $host = $opt{"host"};
  $params = $opt{"snapshot-parameters"};
  $action = "snapshot";
}

# This will parse the command line arguments
sub getInputs {
  my $len = @ARGV;
  if( $len == 0 ){
    die "This plugin is meant to be invoked from mysql-zrm only\n";
  }

  if( $ARGV[0]=~/^--mysqlhotcopy/ ){
    $action = "mysqlhotcopy";
  }elsif( $ARGV[0]=~/^remove-backup-data/ ){
    $action = "remove-backup-data";
  }elsif( $ARGV[0]=~/^--snapshot-command/ ){
    getSnapshotParams();
  }else{
    getCopyParameters();
  }
}


#This will opne the connection to the remote host
sub connectToHost {
  $::PL->m("connect-to-host:\thost:", $host, "\tport:", $REMOTE_PORT);
  my $iaddr = inet_aton($host) or die "no host: $host";
  my $paddr = sockaddr_in($REMOTE_PORT, $iaddr);
  my $proto = getprotobyname('tcp');
  socket(SOCK, PF_INET, SOCK_STREAM, $proto) or die "socket: $!";
  connect(SOCK, $paddr) or die "connect: $!";
  select( SOCK );
  $| = 1;
  select( STDOUT );
  $::PL->m('connected to host.');
}

# This will send the required arguments to the remote host
sub sendArgsToRemoteHost {
  my $tmp = File::Spec->tmpdir();
  my $args = makeKvBlock('action' => $action, 'tmpdir' => $tmp, %config);
  $::PL->m("send-args-to-host:\n", $args);
  print SOCK "$VERSION\n";
  print SOCK $args;
  $_ = <SOCK>;
  if(!/READY/) {
    printAndDie("Socket server did not come up properly. Expected: READY, Got: $_");
  }
}

# This will read the data from the socket and pipe the output to tar
sub readTarStream {
  my $tmpfile = tmpnam();
  my $tar_cmd = "|$TAR $TAR_READ_OPTIONS $destDir 2>$tmpfile";
  $::PL->m("read-tar-stream:\n\t$tar_cmd\n");
  unless( open( TAR_H, "$tar_cmd" ) ){
    printAndDie("tar failed $!");
  }
  binmode( TAR_H );

  my $buf;

  # Initially read the length of data to read
  # This will be packed in network order
  # Then read that much data which is uuencoded
  # Then write the unpacked data to tar
  while( read( SOCK, $buf, 4 ) ){
    $buf = unpack( "N", $buf );
    read SOCK, $buf, $buf;
    print TAR_H unpack( "u", $buf );
  }
  {
    local $/;
    open my $fh, "<$tmpfile";
    my $errs = <$fh>;
    chomp($errs);
    $::PL->e("tar-errors:", $errs) if($errs !~ /\s*/);
    close $fh;
    unlink $tmpfile;
  }
  unless( close(TAR_H) ){
    printAndDie('tar pipe failed');
  }
}

# This will read the data from the socket and pipe the output to tar
sub readInnoBackupStream {
  my $tar_cmd = "|$TAR ";
  my $tmpfile = tmpnam();
  if( $config{'tar-force-ownership'} == 0 ) {
    $tar_cmd .= "--no-same-owner --no-same-permissions -xiC ";
  }
  else {
    $tar_cmd .= "--same-owner -xipC ";
  }
  $tar_cmd .= "$destDir 2>$tmpfile";
  $::PL->m("read-inno-tar-stream:", $tar_cmd);

  unless( open( TAR_H, "$tar_cmd" ) ){
    printAndDie("tar failed $!");
  }
  binmode( TAR_H );

  my $buf;

  # Initially read the length of data to read
  # This will be packed in network order
  # Then read that much data which is uuencoded
  # Then write the unpacked data to tar
  while( read( SOCK, $buf, 4 ) ){
    $buf = unpack( "N", $buf );
    if($buf > 8*1024*1024) {
      # Buffer should never be larger than this.
      # So, we abort if it is.
      # This handles the case where the other side dies
      # and garbage is sent.
      last;
    }
    read SOCK, $buf, $buf;
    print TAR_H unpack( "u", $buf );
  }
  {
    local $/;
    open my $fh, '<', $tmpfile;
    my $errs = <$fh>;
    chomp($errs);
    $::PL->e("tar-errors:", $errs);# if($errs !~ /\s*/);
    close $fh;
    unlink $tmpfile;
  }
  unless( close(TAR_H) ){
    printAndDie("tar pipe failed");
  }

  if( $config{'backup-level'} == 0 and $config{'apply-xtrabackup-log'} == 1 ) {
    $::PL->m("Applying logs..");
    my $r = $::PL->x(sub { system @_; }, "cd $destDir && innobackupex-1.5.1 --apply-log $destDir");
    my $fh = $$r{fh};
    while(<$fh>) { $::PL->m($_); }
    if($$r{rcode} != 0) {
      $::PL->i("Applying the innobackup logs failed.");
    }
    if($$r{error}) { printAndDie("Error executing innobackupex."); }
  }
}

#This will tar the directory and write output to the socket
#$_[0] dirname
#$_[1] filename
sub writeTarStream {
  unless(open( TAR_H, "$TAR $TAR_WRITE_OPTIONS $_[0] $_[1] 2>/dev/null|" ) ){
    printAndDie( "tar failed $!\n" );
  }
  binmode( TAR_H );
  my $buf;
  while( read( TAR_H, $buf, 10240 ) ){
    my $x = pack( "u*", $buf );
    print SOCK pack( "N", length( $x ) );
    print SOCK $x;
  }
  close( TAR_H );
}

#Read the config file
# This reads the conf file that is prepared by mysql-zrm.
# Please note this does not do any validation of the config file
# pointed to by $ZRM_CONF in the enviornment
sub parseConfFile {
  $::PL->d("Reading options from: ", $ENV{ZRM_CONFIG});
  unless( exists $ENV{ZRM_CONF} and %config = IniFile::read_config($ENV{ZRM_CONFIG}) ){
    die "Unable to open config file. The ZRM_CONF environment variable isn't set.\n";
  }
}

# Setup the parameters that are relevant from the conf
sub setUpConfParams {
  if( $config{"socket-remote-port"} ){
    $REMOTE_PORT = $config{"xtrabackup-agent-port"};
  }
  if( defined $ENV{'SNAPSHOT_CONF'} ){
    my $fName = $ENV{'SNAPSHOT_CONF'};
    unless( open( TMP, $fName ) ){
      return;
    }
    @snapshotParamList = <TMP>;
    chomp( @snapshotParamList );
    close TMP;
    unlink( $fName );
    $snapshotConfString = "";
    foreach(@snapshotParamList){
      $snapshotConfString .= "$_=$config{$_}\n";
    }
  }
}

sub doSnapshotCommand {
  $::PL->m("do-snapshot:\tplugin:",$config{'snapshot-plugin'});
  print SOCK $config{"snapshot-plugin"}."\n";
  my $num = @snapshotParamList;
  $num += 2; # For user/pass
  print SOCK "$num\n";
  if( $num > 0 ){
    print SOCK "$snapshotConfString";
    print SOCK "user=$config{'user'}\n";
    print SOCK "password=$config{'password'}\n";
  }
  $::PL->m('  sent config data.');
  my $status = <SOCK>;
  chomp( $status );
  $::PL->m('  result:', $status);
  $num = <SOCK>;
  chomp($num);
  if($num !~ /^\d+$/) {
    printAndDie("$num");
  }
  my $i;
  for( $i = 0 ; $i < $num; $i++ ){
    my $r = <SOCK>;
    if( $status eq "SUCCESS" ){
      $::PL->m(' ', $r);
      print STDOUT $r;
    }else{
      print STDERR $r;
      $::PL->e(' ', $r);
    }
  }
  if( $status ne "SUCCESS" ){
    my_exit(1);
  }
}

sub doCopyBetween()
{
  print SOCK "$REMOTE_PORT\n";
  my $status = <SOCK>;
  chomp( $status );
  my $num = <SOCK>;
  chomp($num);
  my $i;
  for( $i = 0 ; $i < $num; $i++ ){
    my $r = <SOCK>;
    if( $status eq "SUCCESS" ){
      print STDOUT $r;
    }else{
      print STDERR $r;
    }
  }
  if( $status ne "SUCCESS" ){
    my_exit(1);
  }

}

sub main {
  @ARGV = @_;

  $::PL->logpath('syslog:LOCAL0');
  $::PL->start;

  parseConfFile();
  setUpConfParams();

  if($^O eq "linux") {
    $TAR_WRITE_OPTIONS = "--same-owner -cphsC";
    $TAR_READ_OPTIONS = "--same-owner -xphsC";
  }
  elsif($^O eq "freebsd") {
    $TAR_WRITE_OPTIONS = " -cph -f - -C";
    $TAR_READ_OPTIONS = " -xp -f - -C";
  }
  else {
    printAndDie("Unable to determine which tar options to use!");
  }
  
  if( $config{"tar-force-ownership"} == 0 or $config{"tar-force-ownership"} =~ /[Nn][oO]?/ ) {
    $config{"tar-force-ownership"} = 0;
    if( $^O eq "linux" ) {
      $TAR_WRITE_OPTIONS = "--no-same-owner --no-same-permissions -chsC";
      $TAR_READ_OPTIONS = "---no-same-owner --no-same-permissions -xhsC";
    }
    elsif( $^O eq "freebsd" ) {
      $TAR_WRITE_OPTIONS = " -ch -f - -C";
      $TAR_READ_OPTIONS  = " -x -f - -C";
    }
  }
  
  getInputs();
  if(defined $host) {
    connectToHost();
    sendArgsToRemoteHost();
  }
  if( $action eq "copy from" ){
    readInnoBackupStream();
  }elsif( $action eq "mysqlhotcopy" ){
    printAndDie("InnobackupEX is hotcopy. No need for mysqlhotcopy.");
  }elsif( $action eq "copy between" ){
    doCopyBetween();
  }elsif( $action eq "copy to" ){
    my @suf;
    my $file = basename( $srcFile, @suf );
    my $dir = dirname( $srcFile );
    writeTarStream( $dir, $file );
  }elsif( $action eq "snapshot" ){
    doSnapshotCommand( $params );
  }
  close( SOCK );
  select( undef, undef, undef, 0.250 );
  
  my_exit(0);

}

if(!caller) { exit(main(@ARGV)); }
1;