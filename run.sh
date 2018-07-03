#!/bin/bash
# This script downloads gridded data from Smartmet Server (test) for nowcasting purposes. Current state is coming from $USED_OBS (LAPS) and forecasts are from $USED_MODEL (
# The operational mode of the script needs a trigger so that it is run whenever the latest LAPS analysis is ready. Currently it is possible that rounded to previous even hour there's no LAPS analysis available. LAPS analysis gets ready around 20 past?
# This script runs under "verification" mode so that it retrieves data from the past 6 hours from both pal_skandinavia and laps_skandinavia. It uses this data to both interpolate between timesteps and verification. 


# Known issues:
# SOLVED predictability (the max time length over which persistence is applied to) as an input parameter is not applied at the moment
# SOLVED The bbox of DOMAIN SCAND2 is burned to wget retrievals atm. These bbox boundaries would need to be actually loaded in from conf files, which are specified in directory /fmi/dev/run/radar/conf/conf/
# SOLVED laps_skandinavia -grid needs to have similar resolution than edited data (pal_skandinavia). The grid definition needs to be retrieved from the modeldata.nc file
# SOLVED Smartmet server -retrievals currently contain several timesteps...restrict to one analysis and forecast length (defined by predictability). This is fixed just by including timesteps=$PREDICTABILITY to the retrievals.
# SOLVED LAPS_skandinavia -fields are a bit smaller compared to pal_skandinavia -fields because of boundary handling. Probably pal-data needs to be made a bit smaller according to LAPS-boundaries so that the boundaries are not causing any problems in the AMV calculation or the interpolation itself
# SOLVED learn how to read in netcdf files to Pytho
# SOLVED for the function interpolation.advection, variables quantity_min/quantity_max need to be defined specificly for each variable. Simply take these from the fields (omitting the nodata value of course)

# NECESSARY in function read_nc no kind of error checking of the data is being done atm. The min/max values are taken from the raw data as provided.
# NECESSARY nodata fields can (in principle) be different between the timesteps. This causes problems in the beginning of interpolate_and_verify.py
# NECESSARY No instantaneous precipitation in pal_skandinavia dataset? So just take the radar dBz images and scale them according to the 1hour accumulations in pal_skandinavia?
# NECESSARY Farneback parameters: For what are these used? If for optical flow algorithm, what is the sensitivity of the forecasts to them (winsize in particular)?
## What verification metrics would need to be calculated from the sensitivity experiments?
## For practically any verif metrics (like field deformation or similar), previous merged forecasts need to be compared against current analysis. For development this is much much easier if analysis+forecasts are selected to be in the past so that verifying analyses are always available. Verification metrics can be calculated for both motion vectors calculated either forward and backward in time.
### Model forecasts and persistence (skill scores compared to DMO). For temperature also linear cross-dissolve type of approach is needed
### Through using several Farneback parameters (winsize etc)
### As a function of forecast length
## Verification of blended forecasts against PRODUCE THE CLASSIC RMSE-PLOT WHERE THREE (FOUR) CURVES ARE BEING PRODUCED AS A FUNCTION OF TIME (PERSISTENCE, MODEL FCST AND BLENDED FCST. For temperature, also linear cross-dissolve!). Here, blended forecast curves should be produced with several winsizes.


# NECESSARY Visualization of the results? Through Turso-page and R scripts?
# NECESSARY FOR OPERATIVE VERSION No error checking or triggering for the LAPS analysis of current hour whether it is available from Smartmet Server or not
# NECESSARY SHOULD TULISET2 OR LAPS BE USED FOR PRECIPITATION? IF TULISET2, WHAT ABOUT INTERAPPLICABILITY OR SCALING OF THE RR UNITS?
# NECESSARY You need to come up with reasonable R_min / R_max values for also other variables to precipitation. A named list for each parameter?

# RADAR DATA CONVERSION TO EPSG 4326 IS MAYBE MORE PREFERABLE? Data coming from Smartmet Server is not yet reprojected to EPSG 3067 (or whatever projection is defined in $CONFPATH$CONFFILE$PROJ)
# NOT ATM is there any need to have predictability defined in time-span where model data is not available? If this was done, model data would also need to be interpolated from 0 and 3 hour forecasts...Also, in the script call_interpolation.py the variable "n_interp_frames" would need to be accordingly defined as an even number.
# NEXT STEP For precipitation, radar data RATE composites and model data instantaneous RATES would be needed. These would need to have a somewhat comparable temporal resolution.
# QUESTION why filtering R1_f and R2_f in interpolation.py?
#
####### Input parameters ########
# (remember to call shell scripts with named arguments like DATAPATH="/fmi/somepath/" ./run.sh though it is not necessary as there are always default values specified!) 

####### General parameters
PYTHON=${PYTHON:-'/fmi/dev/python_virtualenvs/venv/bin/python'}
USED_OBS=${USED_OBS:-"laps_skandinavia"}
USED_MODEL=${USED_MODEL:-"pal_skandinavia"}
PREDICTABILITY=${PREDICTABILITY:-"6"} # This must be an even number, as model data or production system operates on max one hour temporal resolution.
SECONDS_BETWEEN_STEPS=${SECONDS_BETWEEN_STEPS:-3600} # One hour resolution is required for production. For illustrative purposes of the algorithm, even higher resolution can be used
DOMAIN=${DOMAIN:-"SCAND2"} # this specifies the extent of the domain which is used (the name of the conf file)
CONFDIR=${CONFDIR:-"/fmi/dev/run/radar/conf/conf/"} # All the domain configurations are located here
DATAPATH=${DATAPATH:-"/fmi/data/nowcasting/"}
OUTPATH=${OUTPATH:-"/fmi/$FMI_RUN_ENV/products/cache/nowcasting/"} # Nowcasting fields are output to this directory
OUTFILE_INTERP=${OUTFILE_INTERP:-'{}_${DOMAIN}.nc'}
OUTFILE_SUM=${OUTFILE_SUM:-'{}_5minsum_${DOMAIN}.nc'}
echo $DATAPATH
echo $OUTPATH
if [ ! -d $DATAPATH ]; then
    mkdir --parents $OUTPATH --mode g+rwx
    chgrp fmiprod $DATAPATH
fi

if [ ! -d $OUTPATH ]; then 
    mkdir --parents $OUTPATH --mode g+rwx
    chgrp fmiprod $OUTPATH
fi

####### Time stamps. These are rounded to previous hour.
timestamp_now=`eval date -u -d "now" +"%Y%m%d%H"`00
timestamp_fcst=$(eval 'date -u -d "now + $PREDICTABILITY hour" +"%Y%m%d%H"')00
timestamp_mpredhours=$(eval 'date -u -d "now - $PREDICTABILITY hour" +"%Y%m%d%H"'00)
echo $timestamp_now
echo $timestamp_fcst
echo $timestamp_mpredhours
YEAR=${timestamp_now:0:4}
MONTH=${timestamp_now:4:2}
DAY=${timestamp_now:6:2}


####### Radar data location (composite data used for precipitation nowcasting purposes (dbzH values), here no Tuliset2 nowcast is applied but only the radar composite)
COMPOSITE_DIR="/fmi/$FMI_RUN_ENV/products/cache/radar/rack/comp"
COMPOSITE_BASENAME=`readlink $COMPOSITE_DIR/LATEST_radar.rack.comp_CONF=${DOMAIN}_CAPPI600.h5`
COMPOSITE=$COMPOSITE_DIR/$COMPOSITE_BASENAME
# COMPOSITE=`ls /radar/storage/HDF5/$YEAR/$MONTH/$DAY/radar/cart/comp/rack/*CONF=${DOMAIN}*.h5 | sort | tail -1`
# TIMESTAMP=`basename $COMPOSITE | awk -F_ '{print $1}'`
# TIMESTAMP=`echo $COMPOSITE_BASENAME | awk -F_ '{print $1}'`
# HOUR=${TIMESTAMP:8:2}
# MIN=${TIMESTAMP:10:2}
# DATE=$YEAR$MONTH$DAY' '$HOUR:$MIN

####### Defining actual boundary area
# Read in conf file
query="source "$CONFDIR$DOMAIN".cnf"
# echo $query
eval $query
# echo $BBOX
# echo $PROJ
# echo $SIZE





#MINS_BETWEEN_STEPS=${MINS_BETWEEN_STEPS:-15}
#INPUT1=${INPUT1:-"201608151215_radar.rack.comp_CONF=TULISET2.h5"}
#INPUT2=${INPUT2:-"201608151230_radar.rack.comp_CONF=TULISET2.h5"}
#METHOD=${METHOD:-"proesmans"}
#OUTDIR=${OUTDIR:-"/fmi/dev/run/nowcasting/testdata/"}
#OUTFILE=${OUTFILE:-"201608151230_spoflow.proesmans_ravake.h5"}





#for parameters in Pressure, GeopHeight, Temperature, DewPoint, Humidity, Visibility, PressureAtStationLevel, WindSpeedMS, WindDirection, WindVectorMS, HourlyMaximumGust, WindUMS, WindVMS, SurfaceWaterPhase #these parameters are available for the producer laps_skandinavia
for PARAMETER in Pressure Temperature
do


OBSDATA="$timestamp_now"_"$USED_OBS"_DOMAIN="$DOMAIN"_"$PARAMETER".nc
MODELDATA="$timestamp_now"_fcst"$timestamp_fcst"_"$USED_MODEL"_DOMAIN="$DOMAIN"_"$PARAMETER".nc
echo $OBSDATA
echo $MODELDATA

# : <<'END'

# Working retrieval to ECMWF-data generated by Marko
#wget -O out2.nc --no-proxy 'smartmet.fmi.fi/download?param=Temperature&producer=ecmwf_eurooppa_pinta&format=netcdf&bbox=19.1,59.7,31.7,70.1&timesteps=24&projection=epsg:4326'

# Retrieving pal forecast over Scandinavian domain
query="wget -O "$DATAPATH$MODELDATA" --no-proxy 'http://smartmet.fmi.fi/download?param="$PARAMETER"&producer="$USED_MODEL"&format=netcdf&starttime="$timestamp_mpredhours"&endtime="$timestamp_now"&bbox="$BBOX"&projection=epsg:4326'"
echo $query
eval $query
# Change to netcdf4 type file OR DO THE REPROJECTION HERE AND READ IN NETCDF3 FILES IN PYTHON SCRIPT
query="nccopy -k 4 "$DATAPATH$MODELDATA" "$DATAPATH"modeldata.nc"
echo $query
eval $query
# Retrieve grid information from edited data (modeldata.nc file) and use this to retrieve a grid of same size for laps_skandinavia
query='ncdump -h '$DATAPATH'modeldata.nc | grep "lat ="'
echo $query
SIZE_LAT=$(eval $query)
SIZE_LAT=`echo ${SIZE_LAT:7} | rev`
SIZE_LAT=`echo ${SIZE_LAT:2} | rev`
query='ncdump -h '$DATAPATH'modeldata.nc | grep "lon ="'
echo $query
SIZE_LON=$(eval $query)
SIZE_LON=`echo ${SIZE_LON:7} | rev`
SIZE_LON=`echo ${SIZE_LON:2} | rev`
echo $SIZE_LAT
echo $SIZE_LON

# Retrieving LAPS data over Scandinavian domain
query="wget -O "$DATAPATH$OBSDATA" --no-proxy 'http://smartmet.fmi.fi/download?param="$PARAMETER"&producer="$USED_OBS"&format=netcdf&gridsize="$SIZE_LON","$SIZE_LAT"&starttime="$timestamp_mpredhours"&endtime="$timestamp_now"&bbox="$BBOX"&projection=epsg:4326'"
echo $query
eval $query
# IF NO LAPS AVAILABLE IN OPERATIVE MODE THEN WHAT?! ADD ERROR CHECKING HERE!
# Change to netcdf4 type file OR DO THE REPROJECTION HERE AND READ IN NETCDF3 FILES IN PYTHON SCRIPT
query="nccopy -k 4 "$DATAPATH$OBSDATA" "$DATAPATH"obsdata.nc"
echo $query
eval $query


# FOR THE PROJECTION CONVERSIONS
# this is not working really
# gdalwarp -t_srs epsg:3067 -of netCDF 201805311000_fcst201805311300_pal_skandinavia_DOMAIN\=TULISET2_Pressure.nc output.nc
# This only changes the data type from .nc to HDF5
# see webpage https://stackoverflow.com/questions/17332353/what-is-the-easiest-way-to-convert-netcdf-to-hdf5-on-windows
# see also https://www.unidata.ucar.edu/software/netcdf/docs/interoperability_hdf5.html
# probably it is sufficient to only make projection changes and not turn Netcdf file into HDF5. nc4 files can be read with HDF5 programs and vice versa.





# While retrieving data from Smartmet Server, projection 3067 does not work at the moment. Also, datas are coming with full resolution which might not be the most appropriate thing to do. If there's an option to use a common resolution for all data sources that could be used. Otherwise, interpolation will need to be done after the retrieval.

# END

# Updated call with additional parameters
#cmd=$PYTHON" call_interpolation_testi.py --obsdata "$DATAPATH"obsdata.nc --modeldata "$DATAPATH"modeldata.nc --seconds_between_steps "$SECONDS_BETWEEN_STEPS" --output_interpolate "$OUTPATH$OUTFILE_INTERP" --predictability "$PREDICTABILITY" --parameter "$PARAMETER

# Similar call and parameters as for generate.sh in /fmi/dev/run/radar/amv/spoflow/interpolate/precipfields USE THIS!!
#cmd="$PYTHON call_interpolation.py --first_precip_field $DATAPATH/$OBSDATA_reprojected.nc --second_precip_field $DATAPATH/$MODELDATA_reprojected.nc --seconds_between_steps $SECONDS_BETWEEN_STEPS --output_interpolate $OUTPATH/$OUTFILE_INTERP --output_sum $OUTPATH/$OUTFILE_SUM"
# THIS WORKS!
# cmd="$PYTHON call_interpolation_testi.py --first_precip_field /fmi/data/nowcasting/testdata_radar/opera_rate/T_PAAH21_C_EUOC_20180613120000.hdf --second_precip_field /fmi/data/nowcasting/testdata_radar/opera_rate/T_PAAH21_C_EUOC_20180613121500.hdf --seconds_between_steps 30 --output_interpolate $OUTPATH/$OUTFILE_INTERP --output_sum $OUTPATH/$OUTFILE_SUM"
echo $cmd
eval $cmd

##  Convert output to png?
# OUTFILES=`echo $OUTFILE | awk -F{} '{print $2}'`

##for f in $OUTPATH/*$OUTFILES;do
##    PNGFILE=`basename $f .h5`.png
##    rack $f --encoding C --convert --iResize 496,731 -o $OUTPATH/$PNGFILE
##done


# remove original input files
query="rm "$DATAPATH$OBSDATA
echo $query
eval $query
query="rm "$DATAPATH$MODELDATA
echo $query
eval $query
#query="rm "$DATAPATH"obsdata.nc"
#echo $query
#eval $query
#query="rm "$DATAPATH"modeldata.nc"
#echo $query
#eval $query


 
done


exit
