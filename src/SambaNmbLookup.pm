# File:   	modules/SambaNmbLookup.pm
# Package:	Configuration of samba-client
# Summary:	Data for configuration of samba-client, input and output functions.
# Authors:	Stanislav Visnovsky <visnov@suse.cz>
#		Martin Lazar <mlazar@suse.cz>
#
# $Id$
#
# Representation of the configuration of samba-client.
# Input and output routines. 

package SambaNmbLookup;

use strict;
use Data::Dumper;

use YaST::YCP qw(:DATA :LOGGING);
use YaPI;

textdomain "samba-client";
our %TYPEINFO;

YaST::YCP::Import("SCR");
YaST::YCP::Import("Service");
YaST::YCP::Import("PackageSystem");

use constant {
    # Path to the nmbstatus binary
    NMBSTATUS_EXE => "/usr/bin/nmbstatus",

    TRUE => 1,
    FALSE => 0,
};


# is nmbstatus still running?
our $Nmbstatus_running;

# nmbstatus output
our %Nmbstatus_output;

our $Nmbstatus_available;

# Flag, if we should restart nmbd after finishing nmbstatus.
# nmbd must be stopped, when doing nmbstatus, otherwise only
# local host is shown.
our $Nmbd_was_running;

# Start nmbstatus in background
# @return true on success
BEGIN{$TYPEINFO{Start}=["function","boolean"]}
sub Start {
    my ($self) = @_;

    if (!PackageSystem->Installed("samba-client")) {
	y2error("package samba-client not installed");
	return FALSE;
    }

    # first, check if nmbd is running
    if (PackageSystem->Installed("samba") && Service->Status("nmb")==0) {
        $Nmbd_was_running = 1;
        y2debug("Stopping nmbd for nmbstatus");
        # FIXME: we should check, if stop did not fail
        Service->Stop("nmb");
    }
    
    # start nmbstatus
    my $out = SCR->Execute(".target.bash_output", "/usr/bin/id --user");
    if ($out && $out->{exit} == 0 && $out->{stdout} == 0) {
	$Nmbstatus_running = SCR->Execute(".background.run_output", "su nobody -c " . NMBSTATUS_EXE);
    } else {
	$Nmbstatus_running = SCR->Execute(".background.run_output", NMBSTATUS_EXE);
    }
    if(!$Nmbstatus_running) {
        y2error("Cannot start nmbstatus");
        $Nmbstatus_available = 0;
        # restore nmbd
        if ($Nmbd_was_running) {
	    y2debug("Restarting nmbd for nmbstatus");
	    Service->Start("nmb");
	    $Nmbd_was_running = 0;
	}
	return FALSE;
    }
    
    return TRUE;
}

# Ensure that nmbstatus already finished. Then parse its output into nmbstatus_output
our $wait = 120;
sub checkNmbstatus {
    if ($Nmbstatus_running) {

	# better count slept time
	my $start = time;
	
	while (time<$start+$wait && SCR->Read(".background.isrunning")) {
	    select undef, undef, undef, 0.2; # sleep 0.2 sec
	}
	if (SCR->Read(".background.isrunning")) {
	    y2error("Something went wrong, nmbstatus didn't finish in more that $wait seconds");
	    # better kill it
	    SCR->Execute(".background.kill");
	    $Nmbstatus_running = 0;
	    %Nmbstatus_output = ();
	    $Nmbstatus_available = 0;
	    return;
	}
	
	# nmbstatus already finished, parse the output
	my $output = SCR->Read(".background.newout");
	y2debug("nmbstatus => ".Dumper($output));
	
	$Nmbstatus_available = 1;
	$Nmbstatus_running = 0;
	%Nmbstatus_output = ();
	
	my $current_group = "";
	foreach (@$output) {
	    next unless /^([^\t]+)\t(.+)$/;
	    if ($1 eq "WORKGROUP") {
		$current_group = uc $2;
		$Nmbstatus_output{$current_group} = {};
	    } else {
		$Nmbstatus_output{$current_group}{uc $1} = uc $2;
	    }
	}
	
	# restore nmbd
	if ($Nmbd_was_running) {
	    y2debug("Restarting nmbd for nmbstatus");
	    Service->Start("nmb");
	    $Nmbd_was_running = 0;
	}
    }
}

# Return available flag of nmbstatus.
# @return boolean	true if nmbstatus is available
BEGIN{$TYPEINFO{Available}=["function","boolean"]}
sub Available {
    return $Nmbstatus_available;
}


# Check if a given workgroup is a domain or not. Tests presence of PDC or BDC in the workgroup.
#
# @param workgroup	the name of a workgroup to be tested
# @return boolean	true if the workgroup is a domain
BEGIN{$TYPEINFO{IsDomain}=["function","boolean","string"]}
sub IsDomain {
    my ($self, $workgroup) = @_;
    
    # ensure the data are up-to-date
    checkNmbstatus();

    if (!$self->Available ()) {
	y2milestone ("nmbstatus not available, doing other tests...");
	my $out	= SCR->Execute(".target.bash_output","nmblookup $workgroup#1c");
	my $nmblookup_test	= 0;
	foreach my $line (split (/\n/,$out->{"stdout"} || "")) {
	    next if ($line =~ m/querying/);
	    next if ($line =~ m/failed to find/);
	    if ($line =~ m/$workgroup<1c>/) {
		$nmblookup_test = 1;
	    }

	}
	# assume domain if nmblookup returned something reasonable (#251909)
	return TRUE if $nmblookup_test;
    }
    return FALSE unless $Nmbstatus_output{uc $workgroup};
    
    # if there is PDC, return success
    return TRUE if $Nmbstatus_output{uc $workgroup}{PDC};
    
    # if PDC not found, try BDC
    return TRUE if $Nmbstatus_output{uc $workgroup}{BDC};

    # a different error happened
    return FALSE;
}

# Check if a given workgroup is a PDC or not.
#
# @param workgroup	the name of a workgroup to be tested
# @return boolean	true if the workgroup is a domain
BEGIN{$TYPEINFO{HasPDC}=["function","boolean","string"]}
sub HasPDC {
    my ($self, $workgroup) = @_;
    
    # ensure the data are up-to-date
    checkNmbstatus();

    return FALSE unless $Nmbstatus_output{uc $workgroup};
    
    # if there is PDC, return success
    return TRUE if $Nmbstatus_output{uc $workgroup}{PDC};
    
    # a different error happened
    return FALSE;
}

# Check if a given workgroup is a BDC or not.
#
# @param workgroup	the name of a workgroup to be tested
# @return boolean	true if the workgroup is a domain
BEGIN{$TYPEINFO{HasBDC}=["function","boolean","string"]}
sub HasBDC {
    my ($self, $workgroup) = @_;
    
    # ensure the data are up-to-date
    checkNmbstatus();

    return FALSE unless $Nmbstatus_output{uc $workgroup};
    
    # if there is BDC, return success
    return TRUE if $Nmbstatus_output{uc $workgroup}{BDC};
    
    # a different error happened
    return FALSE;
}

8;
