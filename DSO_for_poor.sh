#!/bin/sh
#
# Grab and display DSO data with either gnuplot's dumb (ascii) or postscript 
# terminal (oscilloscope for the poor or concept demo). The DSO digitizes 
# input signal and prints 100 data points, gnuplot plots them. It is assumed
# input signal is within -0.8..0.8 Volts range. Press Ctr-C to stop the plot.
#
# Prerequisites: - Gnuplot utility has to be installed and reachable through
#		   default path;
#		 - vxi11_cmd executable has to live in ./instruments directory
#		   - see VXI_11 variable below.
#
# To plot data to postscript terminal use gnuplot with ghostscript like:
#
# gnuplot -e 'set term postscript; plot [0:100] [-0.08:0.08] "/tmp/dso.out"' | 
#   gs -q -
#
# 25.07.2019
#


DSO_IP=192.168.0.150			# Oscilloscope's IP address
VXI_11='./instruments/vxi11_cmd'	# VXI-11 interface binary
while true; do
  echo ":WAV:POIN 100; :DIG; :WAV:FORM ASC; :WAV:DATA?" | \
       $VXI_11 $DSO_IP | \
       sed -e 's/^#8\d{8}//; s/,/\n/g' >/tmp/dso.out;	# Remove IEEE heading
  gnuplot -e 'set term dumb; plot [0:100] [-0.8:0.8] "/tmp/dso.out"' 
done


