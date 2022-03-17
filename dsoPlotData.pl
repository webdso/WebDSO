#!/usr/bin/perl -w

#
# dsoPlotData.pl - Backend script to control Agilent's DSO6054x and
#		   similar oscilloscopes and plot data received from the device.
#		   The script receives simple control commands from calling 
#		   HTML page, translates them to SCPI and sends to the DSO with
#		   LXI-11 or TCP protocol (configurable). If oscilloscope
#		   returns signal waveform, the script plots the waveform
#		   using Gnuplot utility and returns ready to display plot in
#		   JS file. The calling HTML page then reads and runs the file
#		   to get the plot on the screen. 
#
# Arguments:	ip - instrument's IP address or null (this causes gnuplot to
#		     plot some predefined function);
#		mode - Plot, Reset, AutoS, TimRange... e mucho mas...;
#		plotW, plotH - plot afrea width and height to send to gnuplot;
#		wP - waveform points to get from DSO;
#		cn - cnannel number to operate, 1-based;
#		color - color to use for plot, RGB hex code like "E69F00";
#		val - free parameter, anything calling page decides to send.
#		
# Dependencies: - vxi11_cmd utility - used to talk to the oscilloscope via
#		  VXI-11 protocol - optional, not recommended as direct TCP 
#		  connection is times faster;
#		- gnuplot - absolutely needed to plot waveforms received from
#			    the scope.
#
# NOTE: 1. Timing: "time -p (./dsoPlotData.pl >/dev/null)" prints 0.19,0.14,0.04
#	   but "time -p (./dsoPlotDemo.sh >/dev/null)" is just 0.08,0.05,0.03.
#	2. For standalone testing w/o real instrument run netcat utility in
#	   server mode: "nc -k -v -l 5025" and set instrument IP to 127.0.0.1
# 
# Version:	BETA
# Release date:	7 Feb.2022
# SVN version:	$Id$
#

#
# Modification history (complements SVN log):
# BETA - 30 Jan.2019: Initial release
# 1.0 - 26 Jan.2022: Latest release
#

package dsoPlotData;
					# To avoid warning under "perl -c" check
BEGIN { $ENV{'DOCUMENT_ROOT'} = '.' if (! $ENV{'DOCUMENT_ROOT'}); }
		
use constant {				# --- Constants ---
  DEV_CONN => 'SOCKET',			# How to talk to device: VXI11 or SOCKET
  VXI11 => 'instruments/vxi11_cmd',	# VXI-11 interface utility
  GNUPLOT => '/usr/local/bin/gnuplot',  # Waveform plotter
  SOCK_PORT => 5025,			# TCP port to talk to the instrument
  SOCK_TMO => 3,			# Timeout when talking through sockets
};
					# -- Local variables --
my(%query);				# URL parameters
my($ip) = 'UNDEFINED';			# Default instrument's IP
my($cmd) = '';				# Command to send to vxi11_cmd
my($sec, $usec);			# Current second and microsecond
my($dsoReply) = '';			# What we get from DSO and return to calling page
my($plotW,$plotH) = (800,600);		# Plot width/height and defaults
my($wP) = 500;				# Default WAVe:POINts for DSO
my($chan,$color) = (1,'ff0000');	# Default channel and color code
my($timer);				# cmCommonTimer object for time measurement
					# -- Mod_perl2 prerequisites --
use lib $ENV{'DOCUMENT_ROOT'};		# Mod_perl2 doesn't do that for us
chdir $ENV{'DOCUMENT_ROOT'};		# Mod_perl2 doesn't change to work dir.
					# -- External stuff --
use dsoCommon qw(ChkErr PrintDebug SetDebug);	
					# -- CPAN modules we need --
use CGI ':cgi';				# Just to get query parameters
use IPC::Cmd qw(run run_forked);	# Need to run external commands
use IO::Socket::INET;			# Another way to talk to instrument
use IO::Socket::Timeout;		# Sockets timeout handling
use autouse 'Errno' => qw(ETIMEDOUT EWOULDBLOCK); # This is for timeouts
use Time::HiRes qw(gettimeofday time);	# Hi-res timing
#use Data::Dumper;			# Too slow to load,uncomment when needed
					# -- START HERE --
$CGI::POST_MAX=1024 * 100;		# Don't accept more than 100K POST
$CGI::DISABLE_UPLOADS = 1;		# Don't accept file uploads
SetDebug(0);				# Disallow debug printout

$q = new CGI;				# Create query object
%query = $q->Vars;			# Get our parameters
$ip = $query{'ip'} if (exists($query{'ip'}));
$plotW = $query{'w'} if (exists($query{'w'}));	# Plot width
$plotH = $query{'h'} if (exists($query{'h'}));	# Height
$wP = $query{'wP'} if (exists($query{'wP'}));	# WAVe:POINts
$chan = $query{'cn'} if (exists($query{'cn'}));
$color = $query{'color'} if (exists($query{'color'}));
					# -- Send out the header
print $q->header(-type=>'text/javascript; charset=utf-8',
		 -pragma=>'no-cache');
		 
if ($query{'mode'} eq 'Plot') {
  $dsoReply = RunPlot($ip,$plotW,$plotH,$wP,$chan,$color);
} elsif ($query{'mode'} eq 'AutoS') {	# Autoscale command
   $dsoReply = DsoStatus($ip,DevIO($ip,":AUT CHAN$chan; :WAV:SOUR CHAN$chan; :CHAN$chan:DISP 1; ".
				       ":TRIG:EDGE:SOUR ".TrgSource($query{'val'},$chan)));
} elsif ($query{'mode'} eq 'TimRef') {	# TIM:REF - plot start: left,center,right
  $dsoReply = DevIO($ip,":TIM:RANG?");
  if ($query{'val'} eq "LEFT") { $cmd = ":TIM:REF LEFT; :TIM:POS ".($dsoReply / 10); }
  elsif ($query{'val'} eq "CENT") { $cmd = ":TIM:REF CENT; :TIM:POS 0"; }
  elsif ($query{'val'} eq "RIGH") { $cmd = ":TIM:REF RIGH; :TIM:POS -".($dsoReply / 10); }
  $dsoReply = DsoStatus($ip,DevIO($ip,$cmd));
} elsif ($query{'mode'} eq 'Coupling') {	# :CHANn:COUP - input AC-AC/DC
  $dsoReply = DsoStatus($ip,DevIO($ip,":CHAN$chan:COUP ".($query{'val'} eq 'AC'? 'AC' : 'DC')));
} elsif ($query{'mode'} eq 'TimRange') {	# :TIM:RANG - set horiz.time
  $dsoReply = DevIO($ip,":TIM:RANG ".$query{'val'}."; :TIM:REF?"); # Plot start
  chomp($dsoReply);			# Get rid of \n added by DSO
  if ($dsoReply eq "LEFT") { $cmd = ":TIM:POS ".($query{'val'} / 10); }
  elsif ($dsoReply eq "RIGH") { $cmd = ":TIM:POS -".($query{'val'} / 10); }
  else { $cmd = ":TIM:POS 0"; } 
  $dsoReply = DsoStatus($ip,DevIO($ip,$cmd));	# Correct X position
} elsif ($query{'mode'} eq 'VertRange') {	# :CHANn:RANG - vert.range
  $dsoReply = DsoStatus($ip,DevIO($ip,":CHAN$chan:RANG ".$query{'val'}."V"));
} elsif ($query{'mode'} eq 'VertScale') {	# :CHANn:SCAL - vert.scale
  $dsoReply = DsoStatus($ip,DevIO($ip,":CHAN$chan:SCAL ".$query{'val'}."V"));
} elsif ($query{'mode'} eq 'TrigCh') {	# Set trigger :TRIG:EDGE:SOUR
  $dsoReply = DsoStatus($ip,DevIO($ip,":TRIG:EDGE:SOUR ".TrgSource($query{'val'},$chan)));
} elsif ($query{'mode'} eq 'Init') {
  $cmd = "*RST; :WAV:POIN:MODE NORM; ".
	 ":CHAN$chan:PROB 10; :CHAN$chan:COUP AC; :CHAN$chan:RANG 16; :CHAN$chan:OFFS 0; ". # NB: Vert.sens.here
	 ":TIM:MODE MAIN; :TIM:REF LEFT; :TIM:POS 0; :TIM:RANG ".$query{'timRang'}.'; '.
	 ":TRIG:MODE EDGE; :TRIG:EDGE:SOUR CHAN$chan; :TRIG:EDGE:SLOP EITH";
  $dsoReply = DsoStatus($ip,DevIO($ip,$cmd));
} elsif ($query{'mode'} eq 'Reset') {		# *RST the scope
  $dsoReply = DsoStatus($ip,DevIO($ip,"*RST"));
} elsif ($query{'mode'} eq 'statReq') {		# Status request, return scope settings
  if (exists($query{'cn'})) {		# Set channel if required
    $dsoReply = DevIO($ip,":WAV:SOUR CHAN$chan;");
  }
  $dsoReply = DsoStatus($ip,$dsoReply);	# Get scope status
} else {
  ChkErr(1,'Invalid mode "'.$query{'mode'}.'", check script parameters');
}

print $dsoReply;
exit;


#------------------------------------------------------------------------------
#                      L O C A L   F U N C T I O N S
#------------------------------------------------------------------------------

#
# RunPlot - get a waveform from DSO, plot it with Gnuplot, return JS function
#	    to show the plot.
#
# NOTE: For some reasons, when gnuplot reads from a pipe or command line under 
#	OpenSUSE 12.3 on the office server, it randomly emits "line 0: warning: 
#	iconv failed to convert degree sign", this goes into generated JS code,
#	and browser skips the plot. This problem was reviewed at
#	https://sourceforge.net/p/gnuplot/bugs/ ticket 1976. Suggested 
#	workaround was to run gnuplot with LANG='en_US.UTF-8' environment. This
#	line was added to gnuplot run command and fixed the problem.
#
# NOTE 2: The following style commands could be used with gnuplot:
#	  set linetype 1 lc rgb "red" lw 1 pt 6 # "lc" and "lw" - line color and width
#         plot sin(x) with {lines|impulses|boxes|dots|points|circle}
#         show style
#         set style fill {solid [0.3] | pattern n}     # For boxes plot
#		    [border ... | noborder]
#
# NOTE 3: Line color and thickness could be given with "plot" command too:
#	  plot sin(x) with lines lc rgb"#0000ff" lw 3
#         
sub RunPlot {
  my($ip,$xSize,$ySize,$pt,$cn,$col) = @_;
  my($sec,$usec,$cmd);			# Timing for imitator and command
  my($timeout);				# DSO data reading timeout
  my($waveForm,$preamble,$range);	# Data,preamble,vert.range from DSO
  my($pFmt,$pTyp,$pPts,$pCnt,		# DSO preamble fields,see :WAV:PRE? in
     $pxInc,$pxOrig,$pxRef,		#  "DSO 6000 series Programmer Guide"
     $pyInc,$pyOrig,$pyRef,$pDummy);
  my($tmScale,$tmAbbr);			# Waveform time scaling coeff. & units
  my($xMin,$xMax);			# X-coord. of 1st and last data points
  if (! $ip) {				# If no IP given - run an imitator
    ($sec,$usec) = gettimeofday();
    $usec = int(($usec / 100000) + 0.5);	# Conv.usec's to tenths of sec.
    $sec = ($sec % 60) . '.' . $usec;		# Current second with the tenth 
    $cmd = "set term canvas enhanced mousing size $xSize,$ySize name 'cs'; ".
	   "set mxtics 10; set mytics 2; set xlabel \'Imitator\'; set ylabel 'Units'; set grid xtics ytics; ".
	   "set style fill solid 0.1 noborder; plot [] [] sin(x+$sec) title '$chan:sin(x+$sec)' with lines lc rgb '\#$col'";
    return( RunCmd("LANG='en_US.UTF-8' ".GNUPLOT." -e \"$cmd\"") );
  }
  $timeout = DevIO($ip,":TIM:RANG?");	# Get acquisition time and adjust timeout
  chomp($timeout);
  $timeout = int($timeout+SOCK_TMO);	
  $cmd = ":WAV:SOUR CHAN$cn; ".
#        ":WAV:POIN $pt; ". 
         ($pt > 1000? ":SYST:PREC ON;" : ":SYST:PREC OFF;")." :WAV:POIN $pt; ". 
         ":SINGLE; :CHAN$cn:DISP 1; ".	# "SINGLE" launches data collection
         ":WAV:FORM ASC; :CHAN$cn:RANG?; :WAV:PRE?; :WAV:DATA?";
  $waveForm = DevIO($ip,$cmd,$timeout);	# Send $cmd to the instrument
  ($range,$preamble,$waveForm) = split(/;/,$waveForm,3); # Separate 3 replies from DSO
  PrintDebug("Ch.range: $range;\nPreamble: $preamble");
  ($pFmt,$pTyp,$pPts,$pCnt,$pxInc,$pxOrig,$pxRef,$pyInc,$pyOrig,$pyRef,$pDummy) =
    split(/,/,$preamble,11);		# Separate preamble fields
  $waveForm = IEEE2Text($waveForm);
  ($tmScale,$tmAbbr) = TimeAbbr($pPts*$pxInc);	# Get time units and scale from waveform timespan
  PrintDebug("Converted: $waveForm");
  $range = $range * 1.1 / 2;		# Half of vert. range + 5% margin
  $xMin = $pxOrig * $tmScale;				# First and last data
  $xMax = (($pPts-1-$pxRef)*$pxInc+$pxOrig) * $tmScale;	#  points X-coord's
  $cmd = "LANG='en_US.UTF-8' ".GNUPLOT." -e \"set term canvas size $xSize,$ySize name 'cs'; " .
         "set mxtics 10; set mytics 2; set xlabel \'$tmAbbr\'; set ylabel 'Volts'; set grid xtics ytics; ".
##	 "plot [] [-$range:$range] '-' ".    # ORIG.ranges code
	 "plot [$xMin:$xMax] [-$range:$range] '-' ".
	 'using (((\$0-'."$pxRef)*$pxInc+$pxOrig)*$tmScale)".":1 title \'Ch.$chan\' with lines lc rgb \'\#$col\'\"";
  return( RunCmd($cmd,$waveForm) );	     
}					# --- RunPlot ---


#
# DsoStatus - send several queries to the instrument to get its operational
#	      parameters. Arrange replies as JS function which returns device
#	      info as an object. It is assumed a calling HTML page runs this
#	      function, parses returned object to local variables and then 
#	      uses DSO settings as needed. Optional $errMsg represents device's 
#	      error message and - if present - is displayed on the screen.
#
# Synopsis:	$statusJs = DsoStatus($ip,[$errMsg]);
#
# NOTE:       The names of the fields in generated JS object must be agreed with
#	      those used in the calling HTML.
# NOTE 2:     For some unknown reasons, DSO takes no less than horiz.time to run
#	      :WAV:POIN? command(!). I.e. if :TIM:RANG is 5 sec, :WAV:POIN?
#	      command takes 5 sec to run (is it nice or what?). Because of this,
#	      we ask :TIM:RANG? first and then compute timeout for next commands. 
#	      Perhaps, better solution would be to get and save :TIM:RANG? first,
#	      then drop it to something short (1 msec or so), then get :WAV:POIN?
#	      value and finally return :TIM:RANG to the original setting.
#
sub DsoStatus {
  my($ip,$errMsg) = @_;			# Grab device's IP and error
  my($cmd,$replyString);		# Instrument's command and reply
  my($timRange);			# DSO current time range (:TIM:RANG?)
  my($timeout);				# Timeout for reading DSO status
  my(@dsoParams);			# DSO operational parameters
  my($tScale,$tUnit);			# Time range usable for humans
  					# -- Get DSP time range and set timeout
  $timRange = DevIO($ip,":TIM:RANG?");	# Get data acquisition time
  chomp($timRange);
  PrintDebug("DSO time range:".$timRange);
  $timeout = int($timRange+SOCK_TMO);	# Adjust timeout
  					# -- Get channel# and common settings
  $cmd = ":WAV:SOUR?; :TIM:REF?; :WAV:POIN?; :TRIG:EDGE:SOUR?";
  $replyString = DevIO($ip,$cmd,$timeout);	# Send command to the device
  @dsoParams = split(/[;\r\n]/,$replyString);	# Separate reply fields
  ($tScale,$tUnit) = TimeAbbr($timRange);	# Conv.time range to convenient form
					# -- Channel specific: coupling, vert.range
  $cmd = ":$dsoParams[0]:COUP?; :$dsoParams[0]:RANG?; :$dsoParams[0]:SCAL?";
  $replyString = DevIO($ip,$cmd); 	# Send channel queries
  push(@dsoParams,split(/[;\r\n]/,$replyString)); # Separate replies and save'em
  PrintDebug("DSO status params parsed:".join(',',@dsoParams));
  $errMsg = defined($errMsg) ? $errMsg : '';
  $errMsg =~ s/'/&#39;/g; $errMsg =~ s/[\n\r]+$//; # Make err.message HTML-ready
  return("function dsoStatus() { \n".
         "  return { wavSour: '".     $dsoParams[0]."',\n".
         "           timRef: '".      $dsoParams[1]."',\n".
         "           wavPoin: '".     $dsoParams[2]."',\n".
         "           timRang: '".     $timRange.    "',\n".
         "           timeScale: '".   $tScale.      "',\n".
         "           timeUnit: '".    $tUnit.       "',\n".
         "           trigEdgeSour: '".$dsoParams[3]."',\n".
         "           chanCoup: '".    $dsoParams[4]."',\n".
         "           chanRang: '".    $dsoParams[5]."',\n".
         "           chanScal: '".    $dsoParams[6]."',\n".
         "           errMsg: '".      $errMsg.      "',\n".
         "           timeCreated: '". localtime().  "',\n".
         "           wasSeen: '".     "".           "'}\n".
         "};\n");
}					# --- DsoStatus ---


#
# DevIO - send command to the DSO via VXI-11 or Telnet - as per static
#	   configuration. This function is just a switch between two methods:
#	   RunCmd() which utilizes VXI-11 protocol and SockIO() which talks to
#	   the instrument through sockets (the former is obviously times faster).
#
# Synopsis:	[$out =] DevIO($ip,$command[,$timeout]);
#
sub DevIO {
  my($ip,$cmd,$tmout) = @_;
  $tmout = SOCK_TMO if (! $tmout);
  return( (DEV_CONN eq 'VXI11') ? RunCmd(VXI11." $ip",$cmd) : SockIO($ip,$cmd,$tmout)
	);
}					# --- DevIO ---


#
# RunCmd - run command with optional arguments, optionally give it input
#	   on STDIN, optionally grab its output and return as a scalar.
#
# Synopsis:	[$out =] RunCmd($command [,$inputData]);
#
sub RunCmd {
  my($cmd,$inputData) = @_;
  my($ok,$err,$outData) = ('','','');	# run[_forked]() completion,error,output
  
  #$timer = cmCommonTimer->new('Reset'=>0);	# Start the timer
  if ($inputData) {			# Any data to send to STDIN?
    PrintDebug("Running with run_forked(): \"$cmd\"");
    $ok = run_forked($cmd,{ child_stdin => $inputData."\n" });
    ChkErr($ok->{exit_code},"Can't run \"$cmd\": ".$ok->{err_msg},
	   "print dsoPlotData::MkJS('Error talking to device') ");
    $outData = $ok->{merged};
  }
  else {				# .No input data - run via open2()
    PrintDebug("Running with run(): \"$cmd\"");
    ($ok,$err) = run(command => $cmd, buffer => \$outData);
    ChkErr(! $ok,"Can't run \"$cmd\": ".(defined($err) ? $err : 'no error message'),
	   "print dsoPlotData::MkJS('Error talking to device') ");
  }
  return($outData);
}					# --- RunCmd ---


#
# SockIO - talk to the instrument over TCP socket. This code was inspired
#	   by an example found in 26_863667_vector_prog.pdf, Signal 
#	   Generators Programming Guide, p.145.
#
# Synopsis:	[$out =] SockIO($ip,$cmd,$timeout);
#
sub SockIO {
  my($ip,$cmd,$timeout) = @_;		# Grab the input
  my($opc) = 0;				# Was *OPC command added to the $cmd?
  my($resp);				# Instrument's reply buffer
  my($sock) = new IO::Socket::INET(PeerAddr => $ip,
				   PeerPort => SOCK_PORT,
				   Proto => 'tcp',
				   Timeout => $timeout,
				  );
  PrintDebug("SockIO: $ip,$cmd,$timeout");
  ChkErr(($ip !~ m/\S/),"Instrument IP address is missing",
	 "print dsoPlotData::MkJS('No instrument IP address given') ");
  ChkErr(! defined($sock),"Can't connect $ip:".SOCK_PORT." - $!", 
	 "print dsoPlotData::MkJS('Cannot connect $ip, port ".SOCK_PORT.": $!') ");
  IO::Socket::Timeout->enable_timeouts_on($sock);
  $sock->read_timeout($timeout);
  if ($cmd !~ m/(\?\s*;)|(\?\s*$)/) { 	# If no device read,add reading command
    $cmd .= "; *OPC?"; 
    $opc = 1;
  }
  print $sock $cmd,"\n";		# Send command
  $resp = <$sock>;			# And read reply
  if (! defined($resp)) {
    $resp = ((0+$! == ETIMEDOUT) || (0+$! == EWOULDBLOCK)) ?
            "Timeout error: no reply from oscilloscope in $timeout sec." :
            "Oscilloscope read error - $!";
    ChkErr(1,$resp,"print dsoPlotData::MkJS(\"$resp\")");
  }
  if ($opc) {				# If we did add *OPC? - remove reply
    if ($resp =~ s/;?(\d+)[\n\r]*$//) {	# *OPC always replies with "1"
      ChkErr(($1 ne '1'),"Invalid reply \"$1\" to *OPC? command",
	     "print dsoPlotData::MkJS('Unexpected reply \"$1\" to *OPC? command') ");
    }
  }
  close($sock);				# Close socket (think mod_perl!)
  return($resp);
}					# --- SockIO ---


#
# MkJS - wrap passed text with JS function code to make the browser properly 
#	 place the text on the calling page.
#
# Synopsis:	$jsCode = MkJS($text);
#
# The function returns: "function cs() { statMsg($text); }" with apostrophes
# within the $text replaced by "&#39;" and LF-CR's removed.
#
sub MkJS {
  my($txt) = shift();
  $txt =~ s/'/&#39;/g; $txt =~ s/[\n\r]+$//;	# Make the text JS-friendly
  return("function cs() { statMsg('$txt'); }");
}					# --- MkJS ---


#
# TrgSource - convert trigger channel we get from calling HTML page to channel
#	      understood by DSO6054L.
#
sub TrgSource {
  my($trg,$defChan) = @_;
  ($trg eq 'E') && return("EXT");		# External trigger
  ($trg =~ m/^[1234]$/) && return("CHAN$trg");	# Trigger by channel
  return("CHAN$defChan");			# Bad trig.source - take default
}					# --- TrgSource --


#
# IEEE2Text - convert text in IEEE format (#Nnnnnn[-]D.DDD,[-]D.DDD...)
#	      to number-per-line format. Returns "undef" if passed string 
#	      does not start with IEEE prefix.
#
# Synopsis:	$clearText = IEEE2Text($IEEEtext);
#
sub IEEE2Text {
  my($ieee) = shift;
  my($prefLen,$prefix);			# IEEE prefix length and prefix #Nnnnn..
  
  if (defined($ieee) && ($ieee =~ m/^#\d/)) {
    $prefLen = substr($ieee,1,1);
    $prefix = substr($ieee,0,$prefLen+2,'');	# Extract prefix and remove it
    return($ieee =~ s/,\s*/\n/gr);	# ** Replace and return **
  }
  return(undef);
}					# --- IEEE2Text ---


#
# TimeAbbr - scale small time interval given in seconds to human-readable
#	     value, return scale factor and abbreviated unit name (like nSec, 
#	     uSec, etc).
#
# Synopsis:	($scale,$unit) = TimeAbbr($timeValue);
#
sub TimeAbbr {
  my($tm) = @_;
  my($tmExp);				# Passed time exponent part
  (undef,$tmExp) = split('E',sprintf('%.6E',abs($tm)));
  return(1e+9,'nsec') if ($tmExp <= -8);
  return(1e+6,'usec') if (($tmExp > -8) && ($tmExp <= -5));
  return(1000,'msec') if (($tmExp > -5) && ($tmExp <= -2));
  return(1,'sec');
}					# --- TimeAbbr ---

exit;					# Keep Perl happy
