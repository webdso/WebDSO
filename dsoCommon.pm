#!/usr/bin/perl -w

#
# dsoCommon.pm - Common functions for DSO scripts. This package contains
#		 various small functions useful for all scripts. The 
#		 package was derived from cmCommon.pm module found elsewhere
#		 in the old shit.
#
# Synopsis:	use dsoCommon;		# Or...
#		use dsoCommon qw(...); 	# Return just those functions needed
#
# Version:	BETA
# Release date:	30 Jan.2019
# SVN version:	$Id$
#

#
# Modification history:
# pre-BETA - 3 Mar.2011: cmCommon.pm initial release;
# BETA - 30 Jan.2019: cmCommon.pm r.1301 was simplified and renamed to  
#		      dsoCommon.pm BETA version.
#

package dsoCommon;

use Exporter 'import';
@EXPORT_OK = qw(ChkErr LogErr PrintDebug SetDebug Daemonize);
					# -- Package-wide variables --
my($DEBUG) = 0;				# Activate debug printout via PrintDebug
					# -- CPAN stuff --
use POSIX "setsid";			# We need it for Daemonize()
					# -- Local variables --


#
# ChkErr - check condition, run $finalCode (if given) and stop the program if
#	   condition is true.
#
# Synopsis:	ChkErr($cond,$msg,$finalCode);
#
# Where:	$cond - if this argument is true, ChkErr exits the script.
#		$msg - message to print on STDERR before exit.
#		$finalCode - if this parameter is given, it is eval'ed
#			     before exiting the script.
# 
sub ChkErr {
  my($cond,$msg,$finalCode) = @_;
  $cond || return(0);			# Condition is false - back to caller
  $msg && LogErr($msg,'ERROR');		# Print the message if given
  $finalCode && eval($finalCode);	# Run termination code if given
  exit;					# *** Quit ***
}					# --- ChkErr ---


#
# LogErr -- send a messssage to STDERR output stream which could be Apache 
#	    error log file or plain text file. If the program works under 
#	    mod_perl ($ENV{'MOD_PERL'} is set) or STDERR was redirected by
#	    Daemonize() function (($ENV{'STDERR'} is set) then output message
#	    is marked with a timestamp, otherwise we assume Apache will care 
#	    about it.
#
# NOTE: Consider replacing this primitive function with Log::Log4perl CPAN 
#	module.
#
# Synopsis:	LogErr($msg[,$prefix]);
#
# Where:	$msg - message to print.
#		$prefix - message severity flag, like DEBUG, ERROR, INFO...
#			  Defaults to "" if not set.
#
sub LogErr {
  my($msg,$prefix) = @_;
  my($myName,@timePieces);
  my($tm) = '';				# Timestamp when we are under mod_perl
  $myName = $0; $myName =~ s|^.*/||;	# Just script name
  if (exists($ENV{'MOD_PERL'}) ||	# We are under mod_perl ..
      exists($ENV{'STDERR'})) {		# or STDERR redirected by Daemonize()?
    @timePieces = localtime(time());	# Create timestamp
    $tm = sprintf(",%03s %02d %02d:%02d:%02d",
		  (('Jan','Feb','Mar','Apr','May','Jun','Jul',
		    'Aug','Sep','Oct','Nov','Dec')[$timePieces[4]]),
		  $timePieces[3], $timePieces[2],
		  $timePieces[1], $timePieces[0]);
  }
  $msg = 'Undefined message in error logger (LogErr)' if (! defined($msg));
  print STDERR "*** $myName\[${$}${tm}".($prefix ? ",$prefix" : '').
	       "\] -- $msg\n"; 		# Send message to Apache log
}					# --- LogErr --


#
# SetDebug - set module-wide debug printout flag. If the flag is set, 
#	     PrintDebug() call will print its argument. It should of been 
#	     better done as a class... will be replaced in the future.
#
# Synopsis:	SetDebug(1); # Activate debug printout past this point
#		SetDebug(0); # De-activate debug printout past this point
#
sub SetDebug {
  $DEBUG = shift() ? 1 : 0;
}					# --- SetDebug ---


#
# PrintDebug - check $DEBUG flag and print passed arguments joined together 
# if the flag is set.
#
# Synopsis:	PrintDebug($msg[,$msg1,..]);
#
# Where:	$msg - message to print.
#
sub PrintDebug {
  $DEBUG && LogErr(join('',@_),'DEBUG');
}					# --- PrintDebug ---


#
# Daemonize - daemonize the process: dissociate the process from the parent,
#	      fork and exit the parent. After return from this function the 
#	      calling program works autonomously, without the parent and
#	      (possibly) STD* streams. The code borrowed from "perlipc" man 
#	      page, more details could be found there.
#
# Synopsis:	Daemonize($newWorkingDir [,$stdFile]);
#
# Where:	$newWorkingDir - Change current directory to this one after
#				 daemonization. If this parameter is "." or
#				 "./" daemonized process keeps running in the
#				 parent's current directory. If this parameter
#				 is missing or null string (""), daemonized
#				 process continues in "/" directory;
#		$stdFile - if this parameter given, STDERR and STDOUT of the 
#			   child process are redirected to this file. Timestamp
#			   message goes to $stdFile when it gets open.
#
sub Daemonize {
  my($newDir,$stdFile) = @_;		# New working directory and file for STD*
  $newDir = '/' if (! defined($newDir));
  if (($newDir ne '.') && ($newDir ne './')) {
    $newDir = '/' if (! $newDir);
    ChkErr(! chdir($newDir),"Can't chdir to \"$newDir\": ".$!);
  }
  ChkErr(! open(STDIN,'< /dev/null'),"Can\'t reassign STDIN to /dev/null: $!");
  ChkErr(! open(STDOUT,'> /dev/null'),"Can\'t reassign STDOUT to /dev/null: $!");
  ChkErr(! defined(my $pid = fork()),"Can\'t fork: $!");
  $pid && exit;				# Non-zero $pid means we are the parent
  ChkErr((setsid() == -1),"Can\'t start a new session: $!");
  ChkErr(! open(STDERR, ">&STDOUT"),"Can\'t dup stdout: $!");
  if ($stdFile) {			# Have to reopen standard streams?
    ChkErr(! open(STDOUT, '>>',$stdFile),"Can\'t open STDOUT on $stdFile: $!");
    ChkErr(! open(STDERR, ">&STDOUT"),"Can\'t dup stdout: $!");
    $ENV{'STDERR'} = $stdFile; $ENV{'STDOUT'} = $stdFile;
    LogErr('Daemonize: STDOUT and STDERR streams redirected to log file','INFO');
  }
}					# --- Daemonize ---


#------------------------------------------------------------------------------
#                             HELPER CLASSES
#------------------------------------------------------------------------------

#
# dsoCommonTimer -- helper class to handle time interval measurements. This
#		    class is needed to measure time intervals spent for
#		    measurements, instruments exchange and other relatively 
#		    slow processes.
#
package dsoCommonTimer;

use Time::HiRes qw(gettimeofday tv_interval);	# Required for dsoCommonTimer class

#
# new - create dsoCommonTimer object and start the timer.
#
# Synopsis:	$timer = dsoCommonTimer->new(%opts);
#
# Where:	%opts - options hash, the following options are supported:
#			"Format" - measured time format string, the string 
#				   must be in printf(3) format, the measured
#				   time is formatted accordingly with this 
#				   string. Default: "%.3f";
#			"Reset" - boolean value, if true, each call to
#				  elapsed() method will reset the timer,
#				  if false, each call will return accumulated
#				  interval of the time. Default is "true",
#				  that is, each call of "elapsed()" will reset
#				  the timer;
#		$timer - dsoCommonTimer object or undef if an error was found.
#
# Example:	$timer = dsoCommonTimer->new('Format' => 'Passed %.5f seconds',
#					     'Reset' => 0);
#
sub new {
  my($class,%opts) = @_;		# Class name and options
  my($self) = { 'Time' => [gettimeofday],
  		'Format' => '%.3f',
  		'Reset' => 1 };		# Allocate the instance, start the timer
  
  $self->{'Format'} = $opts{'Format'} if (exists($opts{'Format'}));
  $self->{'Reset'} = $opts{'Reset'} if (exists($opts{'Reset'}));
  bless($self,$class);
  return($self);			# *** BACK TO CALLER ***
}					# --- dsoCommonTimer->new() ---


#
# elapsed - return time passed since timer object creation OR since previous
#	    call of elapsed() method. The method returns the elapsed time
#	    formatted accordingly with "Format" option and restarts the timer
#	    if no "Restart"=>0 option was set or received.
#
# Synopsis:	$timer->elapsed(%opts);
#
# Where:	%opts - options hash, supported options are "Format" and 
#			"Reset" described with new() method. "Format" option
#			affects just the current call of elapsed() method.
#			"Reset" => 1 option resets the timer (default), 
#			"Reset" => 0 makes the following elapsed() call return
#			the time passed since the previous call.
#		$timer - elapsed time string.
#
# Examples:	$timer->elapsed();	# Returns something like 9.123
#		sleep 1;
#		$timer->elapsed('Format' => 'Passed %.1f sec');	
#					# Returns "Passed 1.2 sec"
#		$timer->elapsed('Reset' => 0);	# Returns 2.23 sec
#
sub elapsed {
  my($self,%opts) = @_;			# Get the instance and options
  $opts{'Format'} = $self->{'Format'} if (! exists($opts{'Format'}));	# Load default format
  my($ela) = sprintf($opts{'Format'}, tv_interval($self->{'Time'}));	# Get the time
  $opts{'Reset'} = $self->{'Reset'} if (! exists($opts{'Reset'}));	# Load Reset option
  $self->{'Time'} = [gettimeofday] if ($opts{'Reset'});	# Reset the timer if requested
  return($ela);				# *** BACK TO CALLER ***
}					# --- dsoCommonTimer->elapsed() ---


1;					# Keeps perl happy

