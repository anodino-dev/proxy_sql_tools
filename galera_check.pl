#!/usr/bin/perl
use strict;
use DBI;
use Time::HiRes qw(gettimeofday);

# This tool is "fat-packed": most of its dependent modules are embedded
# in this file.  

use Getopt::Long;
$Getopt::Long::ignorecase = 0;


my $Param = {};
my $user = "admin";
my $pass = "admin";
my $help = '';
my $host = '' ;
my $outfile;
my $strMySQLVersion="";

my $CurrentTime;
my $CurrentDate;
my $baseSP;
my $debug = 0 ;
my %hostgroups;

my %processState;
my %processCommand;
my @HGIds;




######################################################################
#Local functions
######################################################################

sub URLDecode {
    my $theURL = $_[0];
    $theURL =~ tr/+/ /;
    $theURL =~ s/%([a-fA-F0-9]{2,2})/chr(hex($1))/eg;
    $theURL =~ s/<!--(.|\n)*-->//g;
    return $theURL;
}
sub URLEncode {
    my $theURL = $_[0];
   $theURL =~ s/([\W])/"%" . uc(sprintf("%2.2x",ord($1)))/eg;
   return $theURL;
}

# return a proxy object
sub get_proxy($$$$){
    my $dns = shift;
    my $user = shift;
    my $pass = shift;
    my $debug = shift;
    my $proxynode = ProxySqlNode->new();
    $proxynode->dns($dns);
    $proxynode->user($user);
    $proxynode->password($pass);
    $proxynode->debug($debug);
    
    return $proxynode;
    
}

######################################################################
## get_cluster return a cluster object poulate with the whole info including the 
## $dbh -- a non-null database handle, as returned from get_connection()
##
#sub get_cluster($$) {
#  my $dbh = shift;
#  my $debug = shift;
#  
#  my $cluster=Galeracluster->new();
#  @HGIds=split('\,', $Param->{hostgroups});
#  foreach my $hg (@HGIds){
#    push(@HGIds,($hg + 9000));
#  }
#  
#  $cluster->get_nodes($dbh,$debug);
#  return \$cluster;
#}




# ============================================================================
#+++++ INITIALIZATION
# ============================================================================

$Param->{user}       = '';
$Param->{log}       = undef ;
$Param->{password}   = '';
$Param->{host}       = '';
$Param->{port}       = 3306;
$Param->{debug}      = 0; 
$Param->{processlist} = 0;
$Param->{OS} = $^O;
$Param->{main_segment} = 0;

if (
    !GetOptions(
        'user|u:s'       => \$Param->{user},
        'password|p:s'   => \$Param->{password},
        'host|h:s'       => \$host,
        'port|P:i'       => \$Param->{port},
        'debug|d:i'      => \$Param->{debug},
        'hostgroups|H:s'=> \$Param->{hostgroups},
	'main_segment|S:s'=> \$Param->{main_segment},
        'help:s'       => \$Param->{help}

    )
  )
{
    ShowOptions();
    exit(0);
}
else{
     $Param->{host} = URLDecode($host);
     if(defined $outfile){
          $Param->{outfile} = URLDecode($outfile);
     }
}

if ( defined $Param->{help}) {
    ShowOptions();
    exit(0);
}

die "Option --hostgroups not specified.\n" unless defined($Param->{hostgroups});
die "Option --host not specified.\n" unless defined $Param->{host};
die "Option --user not specified.\n" unless defined $Param->{user};
die "Option --port not specified.\n" unless defined $Param->{port};
#die "Option --log not specified. We need a place to log what is going on, don't we?\n" unless defined $Param->{log};



if($Param->{debug}){
    Utils::debugEnv();
}

# $dsn = "DBI:mysql:database=mysql;mysql_socket=/tmp/mysql.sock";
# my $dbh = DBI->connect($dsn, 'pythian','22yr106xhsy96f4');

my $dsn  = "DBI:mysql:host=$Param->{host};port=$Param->{port}";
if(defined $Param->{user}){
	$user = "$Param->{user}";
}
if(defined $Param->{password}){
	$pass = "$Param->{password}";
}


#============================================================================
# Execution
#============================================================================
if($Param->{debug} == 1){
    print "Start process at " . Utils->get_current_time."\n";
}

if(defined $Param->{log}){
    open(FH, '>>', 'path_to_your_file') or die "cannot open file";
    select FH;
}
 

 while(1 == 1){
my $start = gettimeofday();    

my $proxy_sql_node = get_proxy($dsn, $user, $pass ,$Param->{debug}) ;
$proxy_sql_node->hostgroups($Param->{hostgroups}) ;

$proxy_sql_node->connect();

# create basic galera cluster object and fill info
my $galera_cluster = $proxy_sql_node->get_galera_cluster();

if( defined $galera_cluster){
    $galera_cluster->main_segment($Param->{main_segment});
    $galera_cluster->get_nodes();
}

# Retrive the nodes state
if(defined $galera_cluster->nodes){
    $galera_cluster->process_nodes();
    
}

#Analyze nodes state from ProxySQL prospective;
if(defined  $galera_cluster->nodes){
    my %action_node = $proxy_sql_node->evaluate_nodes($galera_cluster);
    
}

if(defined $proxy_sql_node->action_nodes){
    $proxy_sql_node->push_changes;
}

    my $end = gettimeofday();
    print "END EXECUTION Total Time:".($end - $start) * 1000 ."\n"; 

    $proxy_sql_node->disconnect();
    
    sleep 2;
    
}

#my $dbh = get_connection($dsn, $user, $pass,' ');

#my $variables = get_variables($dbh,$debug);
#my $cluster = get_cluster($dbh,$debug);
if(defined $Param->{log}){
close FH;  # in the end
}



exit(0);






{
    package Galeracluster;
    use threads;
    use threads::shared;
    use strict;
    use warnings;
    use Time::HiRes qw(gettimeofday usleep);
    
    sub new {
        my $class = shift;
        my $SQL_get_mysql_servers=" SELECT a.* FROM mysql_servers a join stats_mysql_connection_pool b on a.hostname=b.srv_host and a.port=b.srv_port and a.hostgroup_id=b.hostgroup  WHERE b.status not in ('OFFLINE_HARD','SHUNNED')";;
        
        
        # Variable section for  looping values
        #Generalize object for now I have conceptualize as:
        # Cluster (generic container)
        # Cluster->{name}     This is the cluster name
        # Cluster->{nodes}       the nodes in the cluster Map by node name
        # Cluster->{status}     cluster status [Primary|not Primary]
        # Cluster->{size}     cluster status [Primary|not Primary]
        # Cluster->{singlenode}=0;  0 if false 1 if true meaning only one ACTIVE node in the cluster 
        # Cluster->{haswriter}=0;  0 if false 1 if true at least a node is fully active as writer
        
        
        my $self = {
            _name      => undef,
            _hosts  => {},
            _status    => undef,
            _size  => {},
            _singlenode  => 0,
            _haswriter => 0,
	    _main_segment => 0,
            _SQL_get_mysql_servers => $SQL_get_mysql_servers,
            _hostgroups => undef,
            _dbh_proxy => undef,
            _debug => 0,
            _monitor_user => undef,
            _monitor_password => undef,
            _nodes => {},
            _check_timeout => 100, #timeout in ms
            #_hg => undef,
        };
        bless $self, $class;
        return $self;
        
    }

    sub main_segment{
        my ( $self, $main_segment ) = @_;
        $self->{_main_segment} = $main_segment if defined($main_segment);
        return $self->{_main_segment};
    }

    sub check_timeout{
        my ( $self, $check_timeout ) = @_;
        $self->{_check_timeout} = $check_timeout if defined($check_timeout);
        return $self->{_check_timeout};
    }

    sub debug{
        my ( $self, $debug ) = @_;
        $self->{_debug} = $debug if defined($debug);
        return $self->{_debug};
    }

    
    sub dbh_proxy{
        my ( $self, $dbh_proxy ) = @_;
        $self->{_dbh_proxy} = $dbh_proxy if defined($dbh_proxy);
        return $self->{_dbh_proxy};
    }
    
    sub name {
        my ( $self, $name ) = @_;
        $self->{_name} = $name if defined($name);
        return $self->{_name};
    }

    sub nodes {
        my ( $self, $nodes ) = @_;
        $self->{_nodes} = $nodes if defined($nodes);
        return $self->{_nodes};
    }
    sub status {
        my ( $self, $status ) = @_;
        $self->{_status} = $status if defined($status);
        return $self->{_status};
    }

    sub size {
        my ( $self, $size ) = @_;
        $self->{_size} = $size if defined($size);
        return $size->{_size};
    }

    sub singlenode {
        my ( $self, $singlenode ) = @_;
        $self->{_singlenode} = $singlenode if defined($singlenode);
        return $self->{_singlenode};
    }

    sub haswriter {
        my ( $self, $haswriter ) = @_;
        $self->{_haswriter} = $haswriter if defined($haswriter);
        return $self->{_haswriter};
    }
    
    sub hostgroups {
        my ( $self, $hostgroups ) = @_;
        $self->{_hostgroups} = $hostgroups if defined($hostgroups);
        return $self->{_hostgroups};
    }
        sub monitor_user{
        my ( $self, $monitor_user ) = @_;
        $self->{_monitor_user} = $monitor_user if defined($monitor_user);
        return $self->{_monitor_user};
    }
    sub monitor_password {
        my ( $self, $monitor_password ) = @_;
        $self->{_monitor_password} = $monitor_password if defined($monitor_password);
        return $self->{_monitor_password};
    }
    # this function is used to identify the nodes in the cluster
    # using the HG as reference
    sub get_nodes{
        my ( $self) = @_;
        
        my $dbh = $self->{_dbh_proxy};
        my $cmd =$self->{_SQL_get_mysql_servers}." AND hostgroup_id IN (".join(",",sort keys($self->hostgroups)).") order by hostgroup_id, hostname";
        my $sth = $dbh->prepare($cmd);
        $sth->execute();
        my $i = 1;
        while (my $ref = $sth->fetchrow_hashref()) {
            my $node = GaleraNode->new();
            $node->dns("DBI:mysql:host=".$ref->{hostname}.";port=".$ref->{port});
            $node->hostgroups($ref->{hostgroup_id});
            $node->ip($ref->{hostname});
	    $node->port($ref->{port});
            $node->weight($ref->{weight});
            $node->user($self->{_monitor_user});
            $node->password($self->{_monitor_password});
            $node->proxy_status($ref->{status});
            $self->{_nodes}->{$i++}=$node;
	    $node->debug($self->debug);
	    if($self->debug){print Utils->get_current_time . " Galera cluster node   " . $node->ip.":". $node->port.":HG=".$node->hostgroups."\n"  }
	}
	if($self->debug){print Utils->get_current_time . " Galera cluster nodes loaded \n" ; }
    }
    #Processing the nodes in the cluster and identify which node is active and which is to remove
    
    sub process_nodes{
        my ( $self ) = @_;

        my $nodes = $self->{_nodes} ;
        my $start = gettimeofday();
        my $run_milliseconds=0;
        my $init =0;
        my $irun = 1;
        my %Threads;
        my $new_nodes ={} ;
	my $processed_nodes ={} ;
        
        #using multiple threads to connect if a node is present in more than one HG it will have 2 threads
        while($irun){
            $irun = 0;
            foreach my $key (sort keys %{$self->{_nodes}}){
                if(!exists $Threads{$key}){
		    if($self->debug){print Utils->get_current_time . " Creating new thread to manage server check:".
				     $self->{_nodes}->{$key}->ip.":".
				     $self->{_nodes}->{$key}->port.":HG".$self->{_nodes}->{$key}->hostgroups."\n"  }
                    $new_nodes->{$key} =  $self->{_nodes}->{$key};
                    $new_nodes->{$key}->{_process_status} = -1;
                    #  debug senza threads
                    $Threads{$key}=threads->create(sub  {return get_node_info($self,$key)});
#                    $new_nodes->{$key} = get_node_info($self,$key);
#		    if(!exists $processed_nodes->{$new_nodes->{$key}->{_ip}} ){
#			$self->{_size}->{$new_nodes->{$key}->{_wsrep_segment}} = (($self->{_size}->{$new_nodes->{$key}->{_wsrep_segment}}|| 0) +1);
#			$processed_nodes->{$new_nodes->{$key}->{_ip}}=$self->{_size}->{$new_nodes->{$key}->{_wsrep_segment}};
#			#print  $self->{_size}->{$new_nodes->{$key}->{_wsrep_segment}}." segment " .$new_nodes->{$key}->{_wsrep_segment} ."\n"
#		    }

		    
                }
            }
            #DEBUG SENZA THREADS coomenta da qui
            foreach my $thr (sort keys %Threads) {
                if ($Threads{$thr}->is_running()) {
                    my $tid = $Threads{$thr}->tid;
                    #print "  - Thread $tid running\n";
                   
                    if($run_milliseconds >  $self->{_check_timeout} ){
			if($self->debug){print Utils->get_current_time . " [WARNING] Check timeout :   " . $tid."\n"  }	
                       $irun = 0 ; 
                    }
		    else{
			$irun = 1;
		    }
                } 
                elsif ($Threads{$thr}->is_joinable()) {
                    my $tid = $Threads{$thr}->tid;
                    ( $new_nodes->{$thr} ) = $Threads{$thr}->join;
		    #count the number of nodes by segment
		    if(($new_nodes->{$thr}->{_process_status} < 0 ||
		       !exists $processed_nodes->{$new_nodes->{$thr}->{_ip}}) ){
			$self->{_size}->{$new_nodes->{$thr}->{_wsrep_segment}} = (($self->{_size}->{$new_nodes->{$thr}->{_wsrep_segment}}|| 0) +1);
			$processed_nodes->{$new_nodes->{$thr}->{_ip}}=$self->{_size}->{$new_nodes->{$thr}->{_wsrep_segment}};
		    }
		    #assign size to HG
		    if($new_nodes->{$thr}->{_proxy_status} ne "OFFLINE_SOFT"){
			$self->{_hostgroups}->{$new_nodes->{$thr}->{_hostgroups}}->{_size} = ($self->{_hostgroups}->{$new_nodes->{$thr}->{_hostgroups}}->{_size}) + 1;
		    }
		    #checks for ONLINE writer(s)
		    if(defined $new_nodes->{$thr}->{_read_only}
		       && $new_nodes->{$thr}->{_read_only} eq "OFF"
		       && $new_nodes->{$thr}->{_proxy_status} eq "ONLINE"){
			$self->{_haswriter} = 1 ;
		    }
		    if($self->debug){print Utils->get_current_time . " Thread joined :   " . $tid."\n"  }	
                    #print "  - Results for thread $tid:\n";
                    #print "  - Thread $tid has been joined\n";
                }
                #print ".";
            }
	    # a qui
            if($self->debug){$run_milliseconds = (gettimeofday() -$start ) *1000};
            #sleep for a time equal to the half of the timeout to save cpu cicle
            #usleep(($self->{_check_timeout} * 1000)/2);
        }
        $self->{_nodes} = $new_nodes;
	if($self->debug){$run_milliseconds = (gettimeofday() -$start ) *1000};
	
	if($debug){
	    foreach my $key (sort keys $new_nodes){
		if($new_nodes->{$key}->{_process_status} == 1){
		    print $new_nodes->{$key}->{_ip}.":".$new_nodes->{$key}->{_hostgroups}." Processed \n";
		}
		else{
		    print $new_nodes->{$key}->{_ip}.":".$new_nodes->{$key}->{_hostgroups}." NOT Processed\n";
		}
	    }
            
	}
	if($self->debug){print Utils->get_current_time . " Multi Thread execution done in :   " . $run_milliseconds. "(ms) \n"  }	
    
    }
    
    sub get_node_info($$){
        my $self = shift;
        my $key = shift;
        my $nodes =shift;
        my ( $node ) = $self->{_nodes}->{$key};
        $node->get_node_info();
	
	return $node;
        
    }
    
}

{
    package GaleraNode;
    #Node Proxy States


    
    sub new {
        my $class = shift;
        my $SQL_get_variables="SHOW GLOBAL VARIABLES LIKE 'wsrep%";
        my $SQL_get_status="SHOW GLOBAL VARIABLES LIKE 'wsrep%";
        my $SQL_get_read_only="SHOW GLOBAL VARIABLES LIKE 'read_only'";  

        # Variable section for  looping values
        #Generalize object for now I have conceptualize as:
        # Node (generic container)
        # Node->{name}     This is the cluster name
        # Node->{IP}
        # Node->{hostgroups}
        # Node->{clustername} This is the cluster name
        # Node->{read_only} Read only node
        # Node->{wsrep_status}     node status (OPEN 0,Primary 1,Joiner 2,Joined 3,Synced 4,Donor 5)
        # Node->{wsrep_rejectqueries} (NON, ALL,ALL_KILL)
        # Node->{wsrep_donorrejectqueries} If true the node when donor 
        # Node->{wsrep_connected}=0;   if false 1 if true meaning only one ACTIVE node in the cluster 
        # Node->{wsrep_desinccount}=0;  0 if false 1 if true at least a node is fully active as writer
        # Node->{wsrep_ready}  ON -OFF 
        
        my $self = {
            _name      => undef,
            _ip  => undef,
	    _port => 3306,
            _hostgroups => undef,
            _clustername    => undef,
            _read_only    => undef,
            _wsrep_status  => -1,
            _wsrep_rejectqueries => undef,
            _wsrep_donorrejectqueries => undef,
            _wsrep_connected => undef,
            _wsrep_desinccount => undef,
            _wsrep_ready => undef,
            _wsrep_provider => [],
            _wsrep_segment => 0,
            _wsrep_pc_weight => 1,
            _SQL_get_variables => $SQL_get_variables,
            _SQL_get_status=> $SQL_get_status,
            _SQL_get_read_only=> $SQL_get_read_only,
            _dns  => undef,
            _user => undef,
            _password => undef,
	    _debug => 0,
            _port => undef,
            _proxy_status    => undef,
            _weight => 1,
            _cluster_status    => undef,
            _cluster_size  => 0,
	    _process_status => -1, 
	    _MOVE_UP_OFFLINE => 1000, #move a node from OFFLINE_SOFT 
	    _MOVE_UP_HG_CHANGE => 1010, #move a node from HG 9000 (plus hg id) to reader HG 
	    _MOVE_DOWN_HG_CHANGE => 3001, #move a node from original HG to maintenance HG (HG 9000 (plus hg id) ) kill all existing connections
	    _MOVE_DOWN_OFFLINE => 3010 , # move node to OFFLINE_soft keep existign connections, no new connections.
	    #_MOVE_SWAP_READER_TO_WRITER => 5001, 
	    #_MOVE_SWAP_WRITER_TO_READER => 5010,

            
        };
        bless $self, $class;
        return $self;
        
    }
    sub process_status {
        my ( $self, $process_status ) = @_;
        $self->{_process_status} = $process_status if defined($process_status);
        return $self->{_process_status};
    }

    sub debug{
        my ( $self, $debug ) = @_;
        $self->{_debug} = $debug if defined($debug);
        return $self->{_debug};
    }

    sub MOVE_UP_OFFLINE {
        my ( $self) = @_;
        return $self->{_MOVE_UP_OFFLINE};
    }

    sub MOVE_UP_HG_CHANGE {
        my ( $self) = @_;
        return $self->{_MOVE_UP_HG_CHANGE};
    }
    
    sub MOVE_DOWN_OFFLINE {
        my ( $self) = @_;
        return $self->{_MOVE_DOWN_OFFLINE};
    }

    sub MOVE_DOWN_HG_CHANGE {
        my ( $self) = @_;
        return $self->{_MOVE_DOWN_HG_CHANGE};
    }

    sub cluster_status {
        my ( $self, $status ) = @_;
        $self->{_cluster_status} = $status if defined($status);
        return $self->{_cluster_status};
    }

    sub cluster_size {
        my ( $self, $size ) = @_;
        $self->{_cluster_size} = $size if defined($size);
        return $size->{_cluster_size};
    }
    
    sub weight {
        my ( $self, $weight ) = @_;
        $self->{_weight} = $weight if defined($weight);
        return $self->{_weight};
    }
    
    sub proxy_status {
        my ( $self, $status ) = @_;
        $self->{_proxy_status} = $status if defined($status);
        return $self->{_proxy_status};
    }
    
    sub dns {
        my ( $self, $dns ) = @_;
        $self->{_dns} = $dns if defined($dns);
        return $self->{_dns};
    }
    
    sub user{
        my ( $self, $user ) = @_;
        $self->{_user} = $user if defined($user);
        return $self->{_user};
    }
    sub password {
        my ( $self, $password ) = @_;
        $self->{_password} = $password if defined($password);
        return $self->{_password};
    }
    sub name {
        my ( $self, $name ) = @_;
        $self->{_name} = $name if defined($name);
        return $self->{_name};
    }

    sub ip {
        my ( $self, $ip ) = @_;
        $self->{_ip} = $ip if defined($ip);
        return $self->{_ip};
    }
    sub port {
        my ( $self, $port ) = @_;
        $self->{_port} = $port if defined($port);
        return $self->{_port};
    }


    sub hostgroups {
        my ( $self, $hostgroups ) = @_;
        $self->{_hostgroups} = $hostgroups if defined($hostgroups);
        return $self->{_hostgroups};
    }
    
    sub clustername {
        my ( $self, $clustername ) = @_;
        $self->{_clustername} = $clustername if defined($clustername);
        return $self->{_clustername};
    }

    sub read_only {
        my ( $self, $read_only ) = @_;
        $self->{_read_only} = $read_only if defined($read_only);
        return $self->{_read_only};
    }

    sub wsrep_status {
        my ( $self, $wsrep_status ) = @_;
        $self->{_wsrep_status} = $wsrep_status if defined($wsrep_status);
        return $self->{_wsrep_status};
    }

    sub wsrep_rejectqueries {
        my ( $self, $wsrep_rejectqueries ) = @_;
        $self->{_wsrep_rejectqueries} = $wsrep_rejectqueries if defined($wsrep_rejectqueries);
        return $self->{_wsrep_rejectqueries};
    }

    sub wsrep_donorrejectqueries {
        my ( $self, $wsrep_donorrejectqueries ) = @_;
        $self->{_wsrep_donorrejectqueries} = $wsrep_donorrejectqueries if defined($wsrep_donorrejectqueries);
        return $self->{_wsrep_donorrejectqueries};
    }

    sub wsrep_connected {
        my ( $self, $wsrep_connected ) = @_;
        $self->{_wsrep_connected} = $wsrep_connected if defined($wsrep_connected);
        return $self->{_wsrep_connected};
    }

    sub wsrep_desinccount {
        my ( $self, $wsrep_desinccount ) = @_;
        $self->{_wsrep_desinccount} = $wsrep_desinccount if defined($wsrep_desinccount);
        return $self->{_wsrep_desinccount};
    }


    sub wsrep_ready {
        my ( $self, $wsrep_ready ) = @_;
        $self->{_wsrep_ready} = $wsrep_ready if defined($wsrep_ready);
        return $self->{_wsrep_ready};
    }

    sub wsrep_segment {
        my ( $self, $wsrep_segment ) = @_;
        $self->{_wsrep_segment} = $wsrep_segment if defined($wsrep_segment);
        return $self->{_wsrep_segment};
    }

    sub wsrep_pc_weight {
        my ( $self, $wsrep_pc_weight ) = @_;
        $self->{_wsrep_pc_weight} = $wsrep_pc_weight if defined($wsrep_pc_weight);
        return $self->{_wsrep_pc_weight};
    }

    sub wsrep_provider {
        my ( $self, $wsrep_provider ) = @_;
        my ( @array)= @{$wsrep_provider} ;
        my %provider_map ;
        foreach my $item (@array){
          my @items = split('\=', $item);
          $provider_map{Utils::trim($items[0])}=$items[1];
        }
        ($self->{_wsrep_provider}) = {%provider_map} ;
        $self->wsrep_segment($provider_map{"gmcast.segment"});
        $self->wsrep_pc_weight($provider_map{"pc.weight"});
        return $self->{_wsrep_provider};
    }

    sub get_node_info($$){
        my ( $self ) = @_;
        
	if($self->debug){print Utils->get_current_time . " Node check START "
	    .$self->{_ip}
	    .":".$self->{_port}
	    .":HG".$self->{_hostgroups}
	    ."\n"  ;}	
	
        my $dbh = Utils::get_connection($self->{_dns},$self->{_user},$self->{_password},' ');
	if(!defined $dbh){
	    return undef;
	}
        my $variables = Utils::get_variables($dbh,0);
        my $status = Utils::get_status_by_name($dbh,0,"wsrep_%");
        
        $self->{_name} = $variables->{wsrep_node_name};
        $self->{_clustername} = $variables->{wsrep_cluster_name};
        $self->{_read_only} = $variables->{read_only};
        $self->{_wsrep_rejectqueries} = $variables->{wsrep_reject_queries};
        $self->{_wsrep_donorrejectqueries} = $variables->{wsrep_sst_donor_rejects_queries};
        my ( @provider ) =  split('\;', $variables->{wsrep_provider_options});
        $self->wsrep_provider( [ @provider]) ;
        $self->{_wsrep_status} = $status->{wsrep_local_state};
        $self->{_wsrep_connected} = $status->{wsrep_connected};
        $self->{_wsrep_desinccount} = $status->{wsrep_desync_count};
        $self->{_wsrep_ready} = $status->{wsrep_ready};
        $self->{_cluster_status} = $status->{wsrep_cluster_status};
        $self->{_cluster_size} = $status->{wsrep_cluster_size};
        
        $dbh->disconnect if (!defined $dbh);
	#sleep 5;
	
        $self->{_process_status} = 1;
	if($self->debug){print Utils->get_current_time . " Node check END "
	    .$self->{_ip}
	    .":".$self->{_port}
	    .":HG".$self->{_hostgroups}
	    ."\n"  ;}	

	return $self;
        
    }
    
}

{
    package ProxySqlNode;
    

    sub new {
        my $class = shift;

        my $SQL_get_monitor = "select variable_name name,variable_value value from global_variables where variable_name in( 'mysql-monitor_username','mysql-monitor_password','mysql-monitor_read_only_timeout' ) order by 1";
        my $SQL_get_hostgroups = "select distinct hostgroup_id hg_isd from mysql_servers order by 1;";
        my $SQL_get_rep_hg = "select writer_hostgroup,reader_hostgroup from mysql_replication_hostgroups order by 1;";

        # Variable section for  looping values
        #Generalize object for now I have conceptualize as:
        # Proxy (generic container)
        # Proxy->{DNS} conenction reference
        # Proxy->{PID} processes pid (angel and real)
        # Proxy->{hostgroups}
        # Proxy->{user} This is the user name
        # Proxy->{password} 
        # Proxy->{port}     node status (OPEN 0,Primary 1,Joiner 2,Joined 3,Synced 4,Donor 5)
        
        my $self = {
            _dns  => undef,
            _pid  => undef,
            _hostgroups => undef,
            _user => undef,
            _password => undef,
            _port => undef,
            _monitor_user => undef,
            _monitor_password => undef,
            _SQL_get_monitor => $SQL_get_monitor,
            _SQL_get_hg=> $SQL_get_hostgroups,
            _SQL_get_replication_hg=> $SQL_get_rep_hg,
            _dbh_proxy => undef,
            _check_timeout => 100, #timeout in ms
	    _action_nodes => {},
        };
        bless $self, $class;
        return $self;
        
    }
    sub debug{
        my ( $self, $debug ) = @_;
        $self->{_debug} = $debug if defined($debug);
        return $self->{_debug};
    }

    sub action_nodes {
        my ( $self, $action_nodes ) = @_;
        $self->{_action_nodes} = $action_nodes if defined($action_nodes);
        return $self->{_action_nodes};
    }
    
    sub dns {
        my ( $self, $dns ) = @_;
        $self->{_dns} = $dns if defined($dns);
        return $self->{_dns};
    }

    sub dbh_proxy{
        my ( $self, $dbh_proxy ) = @_;
        $self->{_dbh_proxy} = $dbh_proxy if defined($dbh_proxy);
        return $self->{_dbh_proxy};
    }

    sub pid {
        my ( $self, $pid ) = @_;
        $self->{_pid} = $pid if defined($pid);
        return $self->{_pid};
    }

    sub hostgroups {
        my ( $self, $hostgroups ) = @_;
	if (defined $hostgroups){
	    my @HGIds=split('\,', $Param->{hostgroups});
	    
	    foreach my $hg (@HGIds){
		my $proxy_hg = ProxySqlHG->new();
		my $proxy_hgM = ProxySqlHG->new();
		my  ($id,$type) = split /:/, $hg;
		$proxy_hg->id($id);
		$proxy_hg->type(lc($type));
		$self->{_hostgroups}->{$id}=($proxy_hg);
		$proxy_hgM->id(($id + 9000));
		$proxy_hgM->type("m".lc($type));
		$self->{_hostgroups}->{$proxy_hgM->id(($id + 9000))}=($proxy_hgM);
		if($self->debug){print Utils->get_current_time . " Inizializing hostgroup " . $proxy_hg->id ." ".$proxy_hg->type . "with maintenance HG ". $proxy_hgM->id ." ".$proxy_hgM->type."\n" ; }
	    }

	    
	}
        return $self->{_hostgroups};
    }
    
    sub user{
        my ( $self, $user ) = @_;
        $self->{_user} = $user if defined($user);
        return $self->{_user};
    }
    sub password {
        my ( $self, $password ) = @_;
        $self->{_password} = $password if defined($password);
        return $self->{_password};
    }
    
        sub monitor_user{
        my ( $self, $monitor_user ) = @_;
        $self->{_monitor_user} = $monitor_user if defined($monitor_user);
        return $self->{_monitor_user};
    }
    sub monitor_password {
        my ( $self, $monitor_password ) = @_;
        $self->{_monitor_password} = $monitor_password if defined($monitor_password);
        return $self->{_monitor_password};
    }

    sub port {
        my ( $self, $port ) = @_;
        $self->{_port} = $port if defined($port);
        return $self->{_port};
    }

    sub check_timeout{
        my ( $self, $check_timeout ) = @_;
        $self->{_check_timeout} = $check_timeout if defined($check_timeout);
        return $self->{_check_timeout};
    }
    
    #Connect method connect an populate the cluster returns the Galera cluster
    sub connect{
        my ( $self, $port ) = @_;
        my $dbh = Utils::get_connection($self->{_dns}, $self->{_user}, $self->{_password},' ');
        $self->{_dbh_proxy} = $dbh;
        
        # get monitor user/pw                
        my $cmd = $self->{_SQL_get_monitor};


        my $sth = $dbh->prepare($cmd);
        $sth->execute();
        while (my $ref = $sth->fetchrow_hashref()) {
            if($ref->{'name'} eq 'mysql-monitor_password' ){$self->{_monitor_password} = $ref->{'value'};}
            if($ref->{'name'} eq 'mysql-monitor_username' ) {$self->{_monitor_user} = $ref->{'value'};}
            if($ref->{'name'} eq 'mysql-monitor_read_only_timeout' ) {$self->{_check_timeout} = $ref->{'value'};}
            
        }
	if($self->debug){print Utils->get_current_time . " Connecting to ProxySQL " . $self->{_dns}. "\n" ; }
        
    }
    sub disconnect{
        my ( $self, $port ) = @_;
        $self->{_dbh_proxy}->disconnect;
	
        
    }

    sub get_galera_cluster(){
        my ( $self, $port ) = @_;
        my $galera_cluster = Galeracluster->new();
        
	$galera_cluster->hostgroups($self->hostgroups);
        $galera_cluster->dbh_proxy($self->dbh_proxy);
        $galera_cluster->check_timeout($self->check_timeout);
        $galera_cluster->monitor_user($self->monitor_user);
        $galera_cluster->monitor_password($self->monitor_password);
        $galera_cluster->debug($self->debug);
	
	if($self->debug){print Utils->get_current_time . " Galera cluster object created  " . caller(3). "\n" ; }
        return $galera_cluster;
    }
    
    sub evaluate_nodes{
	my ($proxynode,$GGalera_cluster)  = @_ ;
	my ( $nodes ) = $GGalera_cluster->{_nodes};
	my $action_nodes = undef;

	#Rules:
	#Gran casino con il prox.
	#NOn si puo usare il read only e il OFFLINE_SOFT mantiene le connessioni aperte quindi non va bene con situazioni dove il node reject queries
	#Ma non reject le connessioni.
	#In quel caso bisogna fare un move di HG
	#muovendo HG il nodo viene disconnesso.
	
	#Quindi ricapitolando
	#1)read-only diventa offline_soft
	#2) Offline_soft con reject diventa move HG
	#Chiesto Rene' di avere uno standard tipo mysql_replication_hostgroups che usa Even per W/R e odd per R.
	#Non so come si potrebbe implementare magari con frazioni. tipo HG 1.5 :)
	
	# Set to offline_soft :
	    #1) any non 4 or 2 state, read only =ON
	    #1) donor node reject queries - 0 size of cluster > 2 of nodes in the same segments more then one writer, node is NOT read_only
	# change HG t maintenance HG:
	    #1) Node/cluster in non primary
	    #2) wsrep_reject_queries different from NONE
	    #3) Donor, node reject queries =1 size of cluster 
	#Set read-only:
	    
		

		
	#Node comes back from offline_soft when (all of them):
	    # 1) Node state is 4
	    # 3) wsrep_reject_queries = none
	    # 4) Primary state
	# Node comes back from maintenance HG when (all of them):
	    # 1) node state is 4
	    # 3) wsrep_reject_queries = none
	    # 4) Primary state
	    
	#do the checks
	if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state ".caller(3)."\n"  }	
	foreach my $key (sort keys %{$nodes}){
            if(defined $nodes->{$key} ){
		
		#only if node has HG that is not maintennce it vcan evaluate to be put down in some way
		if($nodes->{$key}->{_hostgroups} < 9000
		   && $nodes->{$key}->{_process_status} > 0){
		    #Check major exclusions
		    # 1) wsrep state
		    # 2) Node is read only
		    # 3) at least another node in the HG 

		    if( $nodes->{$key}->wsrep_status == 2
			&& $nodes->{$key}->read_only eq "ON"
			&& ($GGalera_cluster->{_hostgroups}->{$nodes->{$key}->{_hostgroups}}->{_size} > 1
			    || $GGalera_cluster->{_main_segment} != {$nodes->{$key}->{_wsrep_segment}}
			    )
			&& $nodes->{$key}->proxy_status ne "OFFLINE_SOFT"
			){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_OFFLINE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_OFFLINE}
			    ."\n"  }	
			next;
		    }


		    if( $nodes->{$key}->wsrep_status ne 4
			&& $nodes->{$key}->wsrep_status ne 2){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}
			    ."\n"  }	

			next;
		    }

		    #3) Node/cluster in non primary
		    if($nodes->{$key}->cluster_status ne "Primary"){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}
			    ."\n"  }	
			next;
		    }		
		    # 4) wsrep_reject_queries=NONE
		    if($nodes->{$key}->wsrep_rejectqueries ne "NONE"){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}
			    ."\n"  }	

			next;
		    }
		    #5) Donor, node reject queries =1 size of cluster > 2 of nodes in the same segments
		    if($nodes->{$key}->wsrep_status eq 2
		       && $nodes->{$key}->wsrep_donorrejectqueries eq "ON"){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_HG_CHANGE}
			    ."\n"  }	

			next;
		    }
		    #Set OFFLINE_SOFT a writer: 
		    #1) donor node reject queries - 0
		    #2)size of cluster > 2 of nodes in the same segments
		    #3) more then one writer in the same HG 
		    
		    if(
		       $nodes->{$key}->wsrep_status eq 2
		       && $nodes->{$key}->read_only eq "OFF"
		       && $nodes->{$key}->wsrep_donorrejectqueries eq "OFF"
		       && $GGalera_cluster->{_size}->{$nodes->{$key}->{_wsrep_segment}} > 2
		       && $GGalera_cluster->{_hostgroups}->{$nodes->{$key}->{_hostgroups}}->{_size} > 1
		       && $nodes->{$key}->proxy_status ne "OFFLINE_SOFT"
		       ){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_OFFLINE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_DOWN_OFFLINE}
			    ."\n"  }	

			next;
		    }
		}    
		#Node comes back from offline_soft when (all of them):
		# 1) Node state is 4
		# 3) wsrep_reject_queries = none
		# 4) Primary state

		if($nodes->{$key}->wsrep_status eq 4
		   && $nodes->{$key}->proxy_status eq "OFFLINE_SOFT"
		   && $nodes->{$key}->wsrep_rejectqueries eq "NONE"
		   &&$nodes->{$key}->cluster_status eq "Primary"
		   && $nodes->{$key}->hostgroups < 9000
		   ){
		    $action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_UP_OFFLINE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_UP_OFFLINE}
			    ."\n"  }			    
		    next;
		}
		
		# Node comes back from maintenance HG when (all of them):
		# 1) node state is 4
		# 3) wsrep_reject_queries = none
		# 4) Primary state
		if($nodes->{$key}->wsrep_status eq 4
		   && $nodes->{$key}->wsrep_rejectqueries eq "NONE"
		   && $nodes->{$key}->cluster_status eq "Primary"
		   && $nodes->{$key}->hostgroups >= 9000
		   ){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_UP_HG_CHANGE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_UP_HG_CHANGE}
			    ."\n"  }			    
			next;
		}

		#Special case when a node goes down it goes through several state and the check disable it moving form original group
		#This is to remove it to his original HG when is not reachable
		   if($nodes->{$key}->{_process_status} < 0 
		    && $nodes->{$key}->hostgroups >= 9000
		   ){
			$action_nodes->{$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_UP_HG_CHANGE}}= $nodes->{$key};
			if($proxynode->debug){print Utils->get_current_time . " Evaluate nodes state "
			    .$nodes->{$key}->ip.";".$nodes->{$key}->port.";".$nodes->{$key}->hostgroups.";".$nodes->{$key}->{_MOVE_UP_HG_CHANGE}
			    ."\n"  }			    
			next;
		}


	    }
	}
	$proxynode->action_nodes($action_nodes);
    }
    
    sub push_changes{
	my ($proxynode)  = @_ ;
	my $node = GaleraNode->new();
	my $SQL_command="";
	
	
	foreach my $key (sort keys %{$proxynode->{_action_nodes}}){
	    my ($host,  $port, $hg, $action) = split /s*;\s*/, $key;
	    SWITCH: {
                if ($action == $node->MOVE_DOWN_OFFLINE) { $proxynode->move_node_offline($key,$proxynode->{_action_nodes}->{$key}); last SWITCH; }
                if ($action == $node->MOVE_DOWN_HG_CHANGE) { $proxynode->move_node_down_hg_changey($key,$proxynode->{_action_nodes}->{$key}); last SWITCH; }
                if ($action == $node->MOVE_UP_OFFLINE) { $proxynode->move_node_up_from_offline($key,$proxynode->{_action_nodes}->{$key}); last SWITCH; }
		if ($action == $node->MOVE_UP_HG_CHANGE) { $proxynode->move_node_up_from_hg_change($key,$proxynode->{_action_nodes}->{$key}); last SWITCH; }
            }
	    
	}
	$proxynode->{_action_nodes} = undef;
    }
    

    sub move_node_offline{
	#this action involve only the proxy so we will 
	my ($proxynode, $key,$node) = @_;
	
	my ($host,  $port, $hg,$action) = split /s*;\s*/, $key;
	my $proxy_sql_command= " UPDATE mysql_servers SET status='OFFLINE_SOFT' WHERE hostgroup_id=$hg AND hostname='$host' AND port='$port'";
	$proxynode->{_dbh_proxy}->do($proxy_sql_command) or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	$proxynode->{_dbh_proxy}->do("LOAD MYSQL SERVERS TO RUNTIME") or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	
	if($proxynode->debug){print Utils->get_current_time . " Move node:" .$key
			    ." SQL:" .$proxy_sql_command
			    ."\n"  }			    
	
    }

    #move a node to a maintenance HG ((9000 + HG id))
    sub move_node_down_hg_changey{
	my ($proxynode, $key,$node) = @_;
	
	my ($host,  $port, $hg,$action) = split /s*;\s*/, $key;
	if($hg > 9000) {return 1;}
	
	my $node_sql_command = "SET GLOBAL READ_ONLY=1;";
	my $proxy_sql_command =" UPDATE mysql_servers SET hostgroup_id=".(9000 + $hg)." WHERE hostgroup_id=$hg AND hostname='$host' AND port='$port'";
	$proxynode->{_dbh_proxy}->do($proxy_sql_command) or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	$proxynode->{_dbh_proxy}->do("LOAD MYSQL SERVERS TO RUNTIME") or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	if($proxynode->debug){print Utils->get_current_time . " Move node:" .$key
	    ." SQL:" .$proxy_sql_command
	    ."\n"  }			    
	
	
    }

    #Bring back a node that is just offline
    sub move_node_up_from_offline{
	
	my ($proxynode, $key,$node) = @_;
	
	my ($host,  $port, $hg,$action) = split /s*;\s*/, $key;
	my $proxy_sql_command= " UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=$hg AND hostname='$host' AND port='$port'";
	$proxynode->{_dbh_proxy}->do($proxy_sql_command) or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	$proxynode->{_dbh_proxy}->do("LOAD MYSQL SERVERS TO RUNTIME") or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	if($proxynode->debug){print Utils->get_current_time . " Move node:" .$key
	    ." SQL:" .$proxy_sql_command
	    ."\n"  }			    
    }
    #move a node back to his original HG ((HG id - 9000))
    sub move_node_up_from_hg_change{
	my ($proxynode, $key,$node) = @_;
	
	my ($host,  $port, $hg,$action) = split /s*;\s*/, $key;
	my $node_sql_command = "SET GLOBAL READ_ONLY=1;";
	my $proxy_sql_command =" UPDATE mysql_servers SET hostgroup_id=".($hg - 9000)." WHERE hostgroup_id=$hg AND hostname='$host' AND port='$port'";
	$proxynode->{_dbh_proxy}->do($proxy_sql_command) or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	$proxynode->{_dbh_proxy}->do("LOAD MYSQL SERVERS TO RUNTIME") or die "Couldn't execute statement: " .  $proxynode->{_dbh_proxy}->errstr;
	if($proxynode->debug){print Utils->get_current_time . " Move node:" .$key
	    ." SQL:" .$proxy_sql_command
	    ."\n"  }			    
    }

}

{
    package ProxySqlHG;
    sub new {
        my $class = shift;
        
        my $self = {
            _id  => undef, # 
            _type  => undef, # available types: w writer; r reader ; mw maintance writer; mr maintenance reader
	    _size => 0,
        };
        bless $self, $class;
        return $self;
    }
    
    sub id {
        my ( $self, $id ) = @_;
        $self->{_id} = $id if defined($id);
        return $self->{_id};
    }

    sub type {
        my ( $self, $type ) = @_;
        $self->{_type} = $type if defined($type);
        return $self->{_type};
    }
    sub size {
        my ( $self, $size ) = @_;
        $self->{_size} = $size if defined($size);
        return $self->{_size};
    }

}

{
    package Utils;
    use Time::HiRes qw(gettimeofday);
    #============================================================================
    ## get_connection -- return a valid database connection handle (or die)
    ## $dsn  -- a perl DSN, e.g. "DBI:mysql:host=ltsdbwm1;port=3311"
    ## $user -- a valid username, e.g. "check"
    ## $pass -- a matching password, e.g. "g33k!"
    
    sub get_connection($$$$) {
      my $dsn  = shift;
      my $user = shift;
      my $pass = shift;
      my $SPACER = shift;
      my $dbh = DBI->connect($dsn, $user, $pass);
    
      if (!defined($dbh)) {
        print Utils->get_current_time ."[ERROR] Cannot connect to $dsn as $user\n";
#        die();
	return undef;
      }
      
      return $dbh;
    }
    
    
    ######################################################################
    ## collection functions -- fetch status data from db
    ## get_status -- return a hash ref to SHOW GLOBAL STATUS output
    ## $dbh -- a non-null database handle, as returned from get_connection()
    ##
    
    sub get_status($$) {
      my $dbh = shift;
      my $debug = shift;
      my %v;
      my $cmd = "show /*!50000 global */ status";
    
      my $sth = $dbh->prepare($cmd);
      $sth->execute();
      while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{'Variable_name'};
        $v{"\L$n\E"} = $ref->{'Value'};
        if ($debug>0){print "MySQL status = ".$n."\n";}
      }
    
      return \%v;
    }
    ######################################################################
    ## collection functions -- fetch status data from db
    ## get_status -- return a hash ref to SHOW GLOBAL STATUS output
    ## $dbh -- a non-null database handle, as returned from get_connection()
    ##
    
    sub get_status_by_name($$) {
      my $dbh = shift;
      my $debug = shift;
      my $name  = shift ; 
      my %v;
      my $cmd = "show /*!50000 global */ status like '$name'";
    
      my $sth = $dbh->prepare($cmd);
      $sth->execute();
      while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{'Variable_name'};
        $v{"\L$n\E"} = $ref->{'Value'};
        if ($debug>0){print "MySQL status = ".$n."\n";}
      }
    
      return \%v;
    }
    ##
    ## get_variables -- return a hash ref to SHOW GLOBAL VARIABLES output
    ##
    ## $dbh -- a non-null database handle, as returned from get_connection()
    ##
    sub get_variables($$) {
      my $dbh = shift;
      my $debug = shift;
      my %v;
      my $cmd = "show variables";
    
      my $sth = $dbh->prepare($cmd);
      $sth->execute();
      while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{'Variable_name'};
        $v{"\L$n\E"} = $ref->{'Value'};
      }
      
     
      return \%v;
    }
    ##
    ## get_variables -- return a hash ref to SHOW GLOBAL VARIABLES output
    ##
    ## $dbh -- a non-null database handle, as returned from get_connection()
    ##
    sub get_variablesByName($$) {
      my $dbh = shift;
      my $variableName = shift;
      #my $debug = shift;
      my %v;
      my $cmd = "show variables like '$variableName'";
    
      my $sth = $dbh->prepare($cmd);
      $sth->execute();
      while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{'Variable_name'};
        $v{"\L$n\E"} = $ref->{'Value'};
      }
      
     
      return \%v;
    }
    
    #Prrint time from invocation with milliseconds
    sub get_current_time{
	use POSIX qw(strftime);
	my $t = gettimeofday();
	my $date = strftime "%Y/%m/%d %H:%M:%S", localtime $t;
	$date .= sprintf ".%03d", ($t-int($t))*1000; # without rounding
	
	return $date;
    }

    #prit all environmnt variables    
    sub debugEnv{
        my $key = keys %ENV;
        foreach $key (sort(keys %ENV)) {
    
           print $key, '=', $ENV{$key}, "\n";
    
        }
    
    }
    
    #trim a string
    sub  trim {
        my $s = shift;
        $s =~ s/^\s+|\s+$//g;
        return $s
    };

}