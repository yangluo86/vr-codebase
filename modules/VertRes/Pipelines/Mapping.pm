=head1 NAME

VertRes::Pipelines::Mapping - pipeline for mapping fastqs to reference

=head1 SYNOPSIS

# make the config files, which specifies the details for connecting to the
# VRTrack g1k-meta database and the data roots:
echo '__VRTrack_Mapping__ g1k_mapping.conf' > pipeline.config
# where g1k_mapping.conf contains:
root    => '/abs/path/to/root/data/dir',
module  => 'VertRes::Pipelines::Mapping',
prefix  => '_',

db  => {
    database => 'g1k_meta',
    host     => 'mcs4a',
    port     => 3306,
    user     => 'vreseq_rw',
    password => 'xxxxxxx',
},

limits => {
    project => ['SRP000031'],
    population => ['CEU', 'TSI'],
    platform => ['SLX'],
},

coverage_limit => {
    min_coverage => 20,
    level => 'individual'
},

data => {
    slx_mapper => 'bwa',
    '454_mapper' => 'ssaha',
    reference => '/abs/path/to/ref.fa',
    assembly_name => 'NCBI37',
    do_recalibration => 1,
    release_date => '20100208'
},

# Reference option can be replaced with male_reference and female_reference
# if you have 2 different references.

# By default it will map all unmapped lanes in a random order. You can limit
# it to only mapping certain lanes by suppling the limits key with a hash ref
# as a value. The hash ref should contain options understood by
# VertRes::Utils::Hierarchy->get_lanes(), as in the example above. The db
# option defaults to the same db settings as supplied elsewhere in the config
# file.
# The example would map only LowCov CEU or TSI lanes that had been imported but
# not mapped already and that had been sequenced on a Selexa platform.

# You can also limit by minimum coverage using the coverage key, where
# the value is a hash ref containing options understood by
# VertRes::Utils::Hierarchy->hierarchy_coverage() with the addition of the
# min_coverage option (db can be included if you want different settings to
# the main db option), requiring the level option and ignoring the lane option.
# Eg. this:
# coverage_limit => {
#     min_coverage => 20,
#     level => 'individual',
#     qc_passed => 1,
#     mapped => 1,
#     db => {
#         database => 'g1k_reseq',
#         host     => 'mcs4a',
#         port     => 3306,
#         user     => 'vreseq_ro'
#     }
# }
# would for each candidate lane determine the mapped coverage of all the lanes
# that share the same individual as the candidate, that had passed QC, according
# to the g1k_reseq database. The coverage would have to be 20x or higher or
# the candidate would be rejected (and so not mapped).

# recalibration is done by default; you can turn it off (if eg. you do not have
# a rod file to recalibrate successfully with) with do_recalibration => 0

# run the pipeline:
run-pipeline -c pipeline.config -s 30

# (and make sure it keeps running by adding that last to a regular cron job)

# alternatively to determining lanes to map with the database, it can work
# on a file of directory paths by altering pipeline.config:
# make a file of absolute paths to your desired lane directories, eg:
find $G1K/data -type d -name "*RR*" | grep -v "SOLID" > lanes.fod
echo '<lanes.fod g1k_mapping.conf' > pipeline.config
# in this case, the db => {} option must be moved in the the data => {} section
# of g1k_mappingf.config

# when complete, get a report:
perl -MVertRes::Utils::Mapping -MVertRes::IO -e '@lanes = VertRes::IO->new->parse_fod("lanes.fod");
VertRes::Utils::Mapping->new->mapping_hierarchy_report("report.csv", @lanes);'

=head1 DESCRIPTION

A module for carrying out mapping on the Vertebrate Resequencing Informatics 
data hierarchy. The hierarchy can consist of multiple different sequencing 
technologies.

*** Currently only Illumina (SLX) and 454 technologies are supported.

This pipeline relies on information stored in a meta database. Such a database
can be created with update_vrmeta.pl, using meta information held in a
(possibly faked) sequence.index

NB: there is an expectation that read fastqs are named [readgroup]_[1|2].*
for paired end sequencing, and [readgroup].* for single ended. Failing this
the forward/reverse/single-ended information about a fastq must be stored in
the database.

=head1 AUTHOR

Sendu Bala: bix@sendu.me.uk

=cut

package VertRes::Pipelines::Mapping;

use strict;
use warnings;
use VertRes::Utils::Mapping;
use VertRes::Utils::Hierarchy;
use VertRes::IO;
use VertRes::Utils::FileSystem;
use VertRes::Parser::bas;
use VRTrack::VRTrack;
use VRTrack::Lane;
use VRTrack::File;
use File::Basename;
use Time::Format;
use LSF;

use base qw(VertRes::Pipeline);

our $actions = [ { name     => 'split',
                   action   => \&split,
                   requires => \&split_requires, 
                   provides => \&split_provides },
                 { name     => 'map',
                   action   => \&map,
                   requires => \&map_requires, 
                   provides => \&map_provides },
                 { name     => 'merge',
                   action   => \&merge,
                   requires => \&merge_requires, 
                   provides => \&merge_provides },
                 { name     => 'recalibrate',
                   action   => \&recalibrate,
                   requires => \&recalibrate_requires, 
                   provides => \&recalibrate_provides },
                 { name     => 'statistics',
                   action   => \&statistics,
                   requires => \&statistics_requires, 
                   provides => \&statistics_provides },
                 { name     => 'update_db',
                   action   => \&update_db,
                   requires => \&update_db_requires, 
                   provides => \&update_db_provides },
                 { name     => 'cleanup',
                   action   => \&cleanup,
                   requires => \&cleanup_requires, 
                   provides => \&cleanup_provides } ];

our %options = (local_cache => '',
                slx_mapper => 'bwa',
                '454_mapper' => 'ssaha',
                do_recalibration => 1,
                do_cleanup => 1);

our $split_dir_name = 'split';

=head2 new

 Title   : new
 Usage   : my $obj = VertRes::Pipelines::Mapping->new(lane => '/path/to/lane');
 Function: Create a new VertRes::Pipelines::Mapping object;
 Returns : VertRes::Pipelines::Mapping object
 Args    : lane => 'readgroup_id'
           lane_path => '/path/to/lane'
           local_cache => '/local/dir' (defaults to standard tmp space)
           do_recalibration => boolean (default true: run the recalibration action)
           do_cleanup => boolean (default true: run the cleanup action)
           chunk_size => int (default depends on mapper)
           slx_mapper => 'bwa'|'maq' (default bwa; the mapper to use for mapping
                                      SLX lanes)
           '454_mapper' => 'ssaha', (default ssaha; the mapper to use for
                                     mapping 454 lanes)
           
           reference => '/path/to/ref.fa' (no default, either this or the
                        male_reference and female_reference pair of args must be
                        supplied)
           assembly_name => 'NCBI36' (no default, must be set to the name of
                                      the reference)
           release_date => 'YYYYMMDD' (defaults to todays date; used for getting
                                       the DCC filename correct in .bas files -
                                       should be the same date as of the DCC
                                       sequence.index used. Not important if
                                       not doing a DCC release afterwards.
                                       Probably not important at all, since this
                                       only affects lane-level bas files, which
                                       are not released)
           
           other optional args as per VertRes::Pipeline

=cut

sub new {
    my ($class, @args) = @_;
    
    my $self = $class->SUPER::new(%options, actions => $actions, @args);
    
    # we should have been supplied the option 'lane_path' which tells us which
    # lane we're in, which lets us choose which mapper module to use.
    my $lane = $self->{lane} || $self->throw("lane readgroup not supplied, can't continue");
    my $lane_path = $self->{lane_path} || $self->throw("lane path not supplied, can't continue");
    my $mapping_util = VertRes::Utils::Mapping->new(slx_mapper => $self->{slx_mapper},
                                                    '454_mapper' => $self->{'454_mapper'});
    my $mapper_class = $mapping_util->lane_to_module($lane_path);
    $mapper_class || $self->throw("Lane '$lane_path' was for an unsupported technology");
    eval "require $mapper_class;";
    $self->{mapper_class} = $mapper_class;
    $self->{mapper_obj} = $mapper_class->new();
    
    # if we've been supplied a list of lane paths to work with, instead of
    # getting the lanes from the db, we won't have a vrlane object; make one
    if (! $self->{vrlane}) {
        $self->throw("db option was not supplied in config") unless $self->{db};
        my $vrtrack = VRTrack::VRTrack->new($self->{db}) or $self->throw("Could not connect to the database\n");
        my $vrlane  = VRTrack::Lane->new_by_name($vrtrack, $lane) or $self->throw("No such lane in the DB: [$lane]");
        $self->{vrlane} = $vrlane;
        
        my $files = $vrlane->files();
        foreach my $file (@{$files}) {
            push @{$self->{files}}, $file->hierarchy_name;
        }
    }
    $self->{vrlane} || $self->throw("vrlane object missing");
    
    # if we've been supplied both male and female references, we'll need to
    # pick one and set the reference option
    unless ($self->{reference} || ($self->{male_reference} && $self->{female_reference})) {
        $self->throw("reference or (male_reference and female_reference) options are required");
    }
    if ($self->{male_reference}) {
        my $vrtrack = $self->{vrlane}->vrtrack;
        my $lib_id = $self->{vrlane}->library_id;
        my $lib = VRTrack::Library->new($vrtrack, $lib_id);
        my $samp_id = $lib->sample_id;
        my $samp = VRTrack::Sample->new($vrtrack, $samp_id);
        my $individual = $samp->individual();
        my $gender = $individual->sex();
        
        if ($gender eq 'F') {
            $self->{reference} = $self->{female_reference};
        }
        elsif ($gender eq 'M') {
            $self->{reference} = $self->{male_reference};
        }
        else {
            $self->throw("gender could not be determined for lane $lane");
        }
    }
    $self->throw("assembly_name must be supplied in conf") unless $self->{assembly_name};
    
    # to allow multiple mappings to be stored in the same lane, our output files
    # are going to be prefixed with a VRTrack::mapstats mapstats_id; discover
    # that id now:
    my $mappings = $self->{vrlane}->mappings();
    my $mapping;
    if ($mappings && @{$mappings}) {
        # find the already created mapping that corresponds to what we're trying
        # to do (we're basically forcing ourselves to only allow one mapping
        # per mapper,version,assembly combo - can't change mapping args and keep
        # that as a separate file)
        foreach my $possible (@{$mappings}) {
            # we're expecting it to have the correct assembly and mapper
            my $assembly = $possible->assembly() || next;
            $assembly->name eq $self->{assembly_name} || next;
            my $mapper = $possible->mapper() || next;
            $mapper->name eq $self->{mapper_obj}->exe || next;
            $mapper->version eq $self->{mapper_obj}->version || next;
            
            $mapping = $possible;
            last;
        }
    }
    unless ($mapping) {
        # make a new mapping
        $mapping = $self->{vrlane}->add_mapping();
        
        # associate it with the assembly name, creating assembly if necessary
        my $assembly = $mapping->assembly($self->{assembly_name});
        if (!$assembly) {
            $assembly = $mapping->add_assembly($self->{assembly_name});
        }
        
        # associate with a mapper, creating that if necessary
        my $mapper = $mapping->mapper($self->{mapper_obj}->exe, $self->{mapper_obj}->version);
        if (!$mapper) {
            $mapper = $mapping->add_mapper($self->{mapper_obj}->exe, $self->{mapper_obj}->version);
        }
        
        $mapping->update || $self->throw("Unable to set mapping details on lane $lane_path");
    }
    $self->{mapstats_obj} = $mapping || $self->throw("Couldn't get an empty mapstats object for this lane from the database");
    $self->{mapstats_id} = $mapping->id;
    
    unless (defined $self->{release_date}) {
        $self->{release_date} = "$time{'yyyymmdd'}"; 
    }
    
    $self->{io} = VertRes::IO->new;
    $self->{fsu} = VertRes::Utils::FileSystem->new;
    
    return $self;
}

=head2 split_requires

 Title   : split_requires
 Usage   : my $required_files = $obj->split_requires('/path/to/lane');
 Function: Find out what files the split action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub split_requires {
    my $self = shift;
    return [$self->_require_fastqs(@_)];
}

sub _require_fastqs {
    my ($self, $lane_path) = @_;
    return @{$self->{files}};
}

=head2 split_provides

 Title   : split_provides
 Usage   : my $provided_files = $obj->split_provides('/path/to/lane');
 Function: Find out what files the split action generates on success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub split_provides {
    my ($self, $lane_path) = @_;
    
    my @provides;
    
    foreach my $ended ('se', 'pe') {
        if ($self->_get_read_args($lane_path, $ended)) {
            push(@provides, '.split_complete_'.$ended.'_'.$self->{mapstats_id});
        }
    }
    
    return \@provides;
}

=head2 split

 Title   : split
 Usage   : $obj->split('/path/to/lane', 'lock_filename');
 Function: Split fastq files into smaller chunks in a subdirectory 'split'.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub split {
    my ($self, $lane_path, $action_lock) = @_;
    
    my $mapper_class = $self->{mapper_class};
    my $verbose = $self->verbose;
    my $chunk_size = $self->{chunk_size} || 0; # if 0, will get set to mapper's default size
    
    # run split in an LSF call to a temp script;
    # we treat read 0 (single ended - se) and read1+2 (paired ended - pe)
    # independantly.
    foreach my $ended ('se', 'pe') {
        my $these_read_args = $self->_get_read_args($lane_path, $ended) || next;
        my @these_read_args = @{$these_read_args};
        
        my $split_dir = $self->{fsu}->catfile($lane_path, $split_dir_name.'_'.$ended.'_'.$self->{mapstats_id});
        my $complete_file = $self->{fsu}->catfile($lane_path, '.split_complete_'.$ended.'_'.$self->{mapstats_id});
        my $script_name = $self->{fsu}->catfile($lane_path, $self->{prefix}."split_${ended}_$self->{mapstats_id}.pl");
        
        open(my $scriptfh, '>', $script_name) or $self->throw("Couldn't write to temp script $script_name: $!");
        print $scriptfh qq{
use strict;
use $mapper_class;
use VertRes::IO;

my \$mapper = $mapper_class->new(verbose => $verbose);

# split
my \$splits = \$mapper->split_fastq(@these_read_args,
                                    split_dir => '$split_dir',
                                    chunk_size => $chunk_size);

# (it will only return >0 if all splits created and checked out fine)
\$mapper->throw("split failed - try again?") unless \$splits;

# note how many splits there are in our complete file
my \$io = VertRes::IO->new(file => ">$complete_file");
my \$fh = \$io->fh;
print \$fh \$splits, "\n";
\$io->close;

exit;
        };
        close $scriptfh;
        
        my $job_name = $self->{prefix}.'split_'.$ended.'_'.$self->{mapstats_id};
        $self->archive_bsub_files($lane_path, $job_name);
        
        LSF::run($action_lock, $lane_path, $job_name, $self->{mapper_obj}->_bsub_opts($lane_path, 'split'), qq{perl -w $script_name});
    }
    
    # we've only submitted to LSF, so it won't have finished; we always return
    # that we didn't complete
    return $self->{No};
}

sub _get_read_args {
    my ($self, $lane_path, $ended) = @_;
    ($ended && ($ended eq 'se' || $ended eq 'pe')) || $self->throw("bad ended arg");
    
    my $lane = basename($lane_path);
    
    my @vrfiles = @{$self->{vrlane}->files};
    my @fastqs = @{$self->{files}};
    my @fastq_info;
    foreach my $vrfile (@vrfiles) {
        my $fastq = $vrfile->hierarchy_name;
        my $type = $vrfile->type;
        if (defined $type && $type =~ /^(0|1|2)$/) {
            $fastq_info[$type]->[0] = $fastq;
        }
        else {
            if ($fastq =~ /${lane}_(\d)\./) {
                $fastq_info[$1]->[0] = $fastq;
            }
            else {
                $fastq_info[0]->[0] = $fastq;
            }
        }
    }
    
    # Petr's mouse track database can have a single se fastq named _1
    if (@fastqs == 1 && ! $fastq_info[0]->[0] && $fastq_info[1]->[0] && ! $self->{vrlane}->is_paired) {
        $fastq_info[0]->[0] = $fastqs[0];
        $fastq_info[1]->[0] = undef;
    }
    
    # before doing a split we will double-check that the fastq files have the
    # correct md5, so we include _md5 options in the read_args
    my @read_args;
    if ($fastq_info[0]->[0]) {
        my $file = 
        $read_args[0] = ["read0 => '".$self->{fsu}->catfile($lane_path, $fastq_info[0]->[0])."', ".
                         "read0_md5 => '".$self->_file_md5($fastq_info[0]->[0])."'"];
    }
    if ($fastq_info[1]->[0] && $fastq_info[2]->[0]) {
        $read_args[1] = ["read1 => '".$self->{fsu}->catfile($lane_path, $fastq_info[1]->[0])."', ".
                         "read1_md5 => '".$self->_file_md5($fastq_info[1]->[0])."', ",
                         "read2 => '".$self->{fsu}->catfile($lane_path, $fastq_info[2]->[0])."', ".
                         "read2_md5 => '".$self->_file_md5($fastq_info[2]->[0])."'"];
    }
    
    @read_args || $self->throw("$lane_path had no compatible set of fastq files!");
    
    if ($ended eq 'se') {
        return $read_args[0];
    }
    elsif ($ended eq 'pe') {
        return $read_args[1];
    }
}

sub _file_md5 {
    my ($self, $filehname) = @_;
    my $vrtrack = $self->{vrlane}->vrtrack;
    my $file = VRTrack::File->new_by_hierarchy_name($vrtrack, $filehname) || $self->throw("Could not get file object from db for $filehname");
    return $file->md5 || $self->throw("No md5 for file $filehname");
}

=head2 map_requires

 Title   : map_requires
 Usage   : my $required_files = $obj->map_requires('/path/to/lane');
 Function: Find out what files the map action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub map_requires {
    my ($self, $lane_path) = @_;
    my @requires = $self->_require_fastqs($lane_path);
    
    # we require the .bwt and .body so that multiple lanes during 'map' action
    # don't all try and create the bwa/ssaha2 reference indexes at once
    # automatically if it is missing; could add an index action before map
    # action to solve this...
    push(@requires,
         $self->{reference},
         $self->{reference}.'.bwt',
         $self->{reference}.'.body',
         $self->{reference}.'.fai',
         $self->{reference}.'.dict');
    
    foreach my $ended ('se', 'pe') {
        if ($self->_get_read_args($lane_path, $ended)) {
            push(@requires, '.split_complete_'.$ended.'_'.$self->{mapstats_id});
        }
    }
    
    return \@requires;
}

=head2 map_provides

 Title   : map_provides
 Usage   : my $provided_files = $obj->map_provides('/path/to/lane');
 Function: Find out what files the map action generates on success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub map_provides {
    my ($self, $lane_path) = @_;
    
    my @provides;
    
    foreach my $ended ('se', 'pe') {
        if ($self->_get_read_args($lane_path, $ended)) {
            push(@provides, '.mapping_complete_'.$ended.'_'.$self->{mapstats_id});
        }
    }
    
    return \@provides;
}

=head2 map

 Title   : map
 Usage   : $obj->map('/path/to/lane', 'lock_filename');
 Function: Carry out mapping of the split fastq files in a lane directory to the
           reference genome. Always generates a bam file ('[splitnum].raw.sorted.bam')
           per split, regardless of the technology/ mapping tool.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub map {
    my ($self, $lane_path, $action_lock) = @_;
    
    # get the reference filename
    my $ref_fa = $self->{reference} || $self->throw("the reference fasta wasn't known for $lane_path");
    
    # get all the meta info about the lane
    my %info = VertRes::Utils::Hierarchy->new->lane_info($self->{vrlane});
    my $insert_size_for_mapping = $info{insert_size} || 2000;
    my $insert_size_for_samheader = $info{insert_size} || 0;
    
    my $mapper_class = $self->{mapper_class};
    my $verbose = $self->verbose;
    
    # run mapping of each split in LSF calls to temp scripts;
    # we treat read 0 (single ended - se) and read1+2 (paired ended - pe)
    # independantly.
    foreach my $ended ('se', 'pe') {
        my $done_file = $self->{fsu}->catfile($lane_path, '.mapping_complete_'.$ended.'_'.$self->{mapstats_id});
        next if -e $done_file;
        my $these_read_args = $self->_get_read_args($lane_path, $ended) || next;
        my @these_read_args = @{$these_read_args};
        
        # get the number of splits
        my $num_of_splits = $self->_num_of_splits($lane_path, $ended);
        my $split_dir = $self->{fsu}->catfile($lane_path, $split_dir_name.'_'.$ended.'_'.$self->{mapstats_id});
        
        foreach my $split (1..$num_of_splits) {
            my $sam_file = $self->{fsu}->catfile($split_dir, $split.'.raw.sam');
            my $bam_file = $self->{fsu}->catfile($split_dir, $split.'.raw.sorted.bam');
            
            next if -s $bam_file;
            
            my $script_name = $self->{fsu}->catfile($split_dir, $self->{prefix}.$split.'.map.pl');
            
            my @split_read_args = ();
            foreach my $read_arg (@these_read_args) {
                my $split_read_arg = $read_arg;
                $split_read_arg =~ s/\.f[^.]+(?:\.gz)?('(?:, )?).*$/.$split.fastq.gz$1/;
                $split_read_arg =~ s/\/([^\/]+)$/\/${split_dir_name}_${ended}_$self->{mapstats_id}\/$1/;
                push(@split_read_args, $split_read_arg);
            }
            
            my $job_name = $self->{prefix}.'map_'.$ended.'_'.$self->{mapstats_id}.'_'.$split;
            my $prev_error_file = $self->archive_bsub_files($lane_path, $job_name) || '';
            
            open(my $scriptfh, '>', $script_name) or $self->throw("Couldn't write to temp script $script_name: $!");
            print $scriptfh qq{
use strict;
use $mapper_class;
use VertRes::Utils::Sam;

my \$mapper = $mapper_class->new(verbose => $verbose);

# mapping won't get repeated if mapping works the first time but subsequent
# steps fail
my \$ok = \$mapper->do_mapping(ref => '$ref_fa',
                               @split_read_args
                               output => '$sam_file',
                               insert_size => $insert_size_for_mapping,
                               read_group => '$info{lane}',
                               error_file => '$prev_error_file');

# (it will only return ok and create output if the sam file was created and not
#  truncated)
\$mapper->throw("mapping failed - try again?") unless \$ok;

# add sam header
my \$sam_util = VertRes::Utils::Sam->new(verbose => $verbose);
open(my \$samfh, '$sam_file') || \$mapper->throw("Unable to open sam file '$sam_file'");
my \$head = <\$samfh>;
close(\$samfh);
unless (\$head =~ /^\\\@HD/) {
    my \$ok = \$sam_util->add_sam_header('$sam_file',
                                         sample_name => '$info{sample}',
                                         library => '$info{library_true}',
                                         platform => '$info{technology}',
                                         centre => '$info{centre}',
                                         insert_size => $insert_size_for_samheader,
                                         project => '$info{project}',
                                         lane => '$info{lane}',
                                         ref_fa => '$ref_fa',
                                         ref_dict => '$ref_fa.dict',
                                         ref_name => '$self->{assembly_name}',
                                         program => \$mapper->exe,
                                         program_version => \$mapper->version);
    \$sam_util->throw("Failed to add sam header!") unless \$ok;
}

# convert to mate-fixed sorted bam
unless (-s '$bam_file') {
    my \$ok = \$sam_util->sam_to_fixed_sorted_bam('$sam_file', '$bam_file', '$ref_fa');
    
    unless (\$ok) {
        # (will only return ok and create output bam file if bam was created and
        #  not truncted)
        \$sam_util->throw("Failed to create sorted bam file!");
    }
    else {
        unlink('$sam_file');
    }
}

exit;
            };
            close $scriptfh;
            
            LSF::run($action_lock, $lane_path, $job_name, $self->{mapper_obj}->_bsub_opts($lane_path, 'map'), qq{perl -w $script_name});
        }
    }
    
    # we've only submitted to LSF, so it won't have finished; we always return
    # that we didn't complete
    return $self->{No};
}

sub _num_of_splits {
    my ($self, $lane_path, $ended) = @_;
    
    # get the number of splits
    my $split_file = $self->{fsu}->catfile($lane_path, '.split_complete_'.$ended.'_'.$self->{mapstats_id});
    my $io = VertRes::IO->new(file => $split_file);
    my $split_fh = $io->fh;
    my $splits = <$split_fh>;
    $splits || $self->throw("Unable to read the number of splits from split file '$split_file'");
    chomp($splits);
    $io->close;
    
    return $splits;
}

=head2 merge_requires

 Title   : merge_requires
 Usage   : my $required_files = $obj->merge_requires('/path/to/lane');
 Function: Find out what files the merge_and_stat action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub merge_requires {
    my ($self, $lane_path) = @_;
    
    my @requires;
    
    foreach my $ended ('se', 'pe') {
        $self->_get_read_args($lane_path, $ended) || next;
        
        # if we already merged this ended, we don't require the files in the
        # split dir, which in strange and unusual (manual intervention...)
        # circumstances, might not exist
        my $bam = $self->{fsu}->catfile($lane_path, "$self->{mapstats_id}.$ended.raw.sorted.bam");
        next if -s $bam;
        
        # get the number of splits
        my $num_of_splits = $self->_num_of_splits($lane_path, $ended);
        my $split_dir = $self->{fsu}->catfile($lane_path, $split_dir_name.'_'.$ended.'_'.$self->{mapstats_id});
        
        foreach my $split (1..$num_of_splits) {
            push(@requires, $self->{fsu}->catfile($split_dir, $split.'.raw.sorted.bam'));
        }
    }
    
    @requires || $self->throw("Something went wrong; we don't seem to require any bams!");
    
    return \@requires;
}

=head2 merge_provides

 Title   : merge_provides
 Usage   : my $provided_files = $obj->merge_provides('/path/to/lane');
 Function: Find out what files the merge_and_stat action generates on success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub merge_provides {
    my ($self, $lane_path) = @_;
    
    my @provides;
    
    foreach my $ended ('se', 'pe') {
        $self->_get_read_args($lane_path, $ended) || next;
        
        my $file = "$self->{mapstats_id}.$ended.raw.sorted.bam";
        
        # if we're doing recalibration and that completed, our raw bam will
        # have been deleted so it will look like on subsequent pipeline runs
        # this action hasn't worked; detect that and say we provide recal
        # files instead
        if ($self->{do_recalibration}) {
            unless (-s $self->{fsu}->catfile($lane_path, $file)) {
                my $recal_file = "$self->{mapstats_id}.$ended.recal.sorted.bam";
                if (-s $self->{fsu}->catfile($lane_path, $recal_file)) {
                    $file = $recal_file;
                }
            }
        }
        
        push(@provides, $file);
    }
    
    @provides || $self->throw("Something went wrong; we don't seem to provide any merged bams!");
    
    return \@provides;
}

=head2 merge

 Title   : merge
 Usage   : $obj->merge('/path/to/lane', 'lock_filename');
 Function: Takes the bam files generated during map(), and creates a merged,
           sorted bam file from them.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub merge {
    my ($self, $lane_path, $action_lock) = @_;
    
    # setup filenames etc. we'll use within our temp script
    my $mapper_class = $self->{mapper_class};
    my $verbose = $self->verbose;
    
    # we treat read 0 (single ended - se) and read1+2 (paired ended - pe)
    # independantly.
    foreach my $ended ('se', 'pe') {
        $self->_get_read_args($lane_path, $ended) || next;
        
        my $script_name = $self->{fsu}->catfile($lane_path, $self->{prefix}."merge_${ended}_$self->{mapstats_id}.pl");
        
        # get the input bams that need merging
        my $num_of_splits = $self->_num_of_splits($lane_path, $ended);
        my $split_dir = $self->{fsu}->catfile($lane_path, $split_dir_name.'_'.$ended.'_'.$self->{mapstats_id});
        my @bams;
        foreach my $split (1..$num_of_splits) {
            push(@bams, $self->{fsu}->catfile($split_dir, $split.'.raw.sorted.bam'));
        }
        
        my $copy_instead_of_merge = @bams > 1 ? 0 : 1;
        my $bam_file = $self->{fsu}->catfile($lane_path, "$self->{mapstats_id}.$ended.raw.sorted.bam");
        
        # run this in an LSF call to a temp script
        open(my $scriptfh, '>', $script_name) or $self->throw("Couldn't write to temp script $script_name: $!");
        print $scriptfh qq{
use strict;
use VertRes::Wrapper::samtools;
use File::Copy;

my \$samtools = VertRes::Wrapper::samtools->new(verbose => $verbose);

# merge bams
unless (-s '$bam_file') {
    # (can't use VertRes::Utils::Sam->merge since that is implemented with
    #  picard, which renames the RG tags (to uniquify) when it merges multiple
    #  files with the same RG tag!
    if ($copy_instead_of_merge) {
        copy('@bams', '$bam_file') || die "copy of bam failed: $!\n";
    }
    else {
        \$samtools->merge_and_check('$bam_file', [qw(@bams)]);
        die "merging bam failed - try again?\n" unless \$samtools->run_status == 2;
    }
}

exit;
        };
        close $scriptfh;
        
        my $job_name = $self->{prefix}.'merge_'.$ended.'_'.$self->{mapstats_id};
        $self->archive_bsub_files($lane_path, $job_name);
        
        LSF::run($action_lock, $lane_path, $job_name, $self->{mapper_obj}->_bsub_opts($lane_path, 'merge'), qq{perl -w $script_name});
    }
    
    # we've only submitted to LSF, so it won't have finished; we always return
    # that we didn't complete
    return $self->{No};
}


=head2 recalibrate_requires

 Title   : recalibrate_requires
 Usage   : my $required_files = $obj->recalibrate_requires('/path/to/lane');
 Function: Find out what files the recalibrate action needs before
           it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub recalibrate_requires {
    my ($self, $lane_path) = @_;
    
    # we need bams
    my @requires = @{$self->merge_provides($lane_path)};
    
    # and reference-related files
    my $ref = $self->{reference};
    my $dict = $ref;
    $dict =~ s/\.[^\.]+$/.dict/;
    push(@requires, $ref);
    push(@requires, $dict);
    push(@requires, $ref.'.rod');
    
    return \@requires;
}

=head2 recalibrate_provides

 Title   : recalibrate_provides
 Usage   : my $provided_files = $obj->recalibrate_provides('/path/to/lane');
 Function: Find out what files the recalibrate action generates on
           success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub recalibrate_provides {
    my ($self, $lane_path) = @_;
    
    my @raw_bams = @{$self->merge_provides($lane_path)};
    my @recal_bams;
    foreach my $bam (@raw_bams) {
        my $recal_bam = $bam;
        $recal_bam =~ s/\.raw\.sorted\.bam$/.recal.sorted.bam/;
        push(@recal_bams, $recal_bam);
    }
    
    return $self->{do_recalibration} ? \@recal_bams : \@raw_bams;
}

=head2 recalibrate

 Title   : recalibrate
 Usage   : $obj->recalibrate('/path/to/lane', 'lock_filename');
 Function: Recalibrate the quality values of bams. (Original quality values are
           retained in the file.)
           Doesn't run unless do_recalibration config option is true (default).
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub recalibrate {
    my ($self, $lane_path, $action_lock) = @_;
    return $self->{Yes} unless $self->{do_recalibration};
    
    my @in_bams = @{$self->merge_provides($lane_path)};
    my $verbose = $self->verbose;
    
    my $orig_bsub_opts = $self->{bsub_opts};
    $self->{bsub_opts} = '-q normal -M6500000 -R \'select[mem>6500] rusage[mem=6500]\'';
    
    my $build = $self->{assembly_name};
    
    my @out_bams;
    foreach my $bam (@in_bams) {
        $bam = $self->{fsu}->catfile($lane_path, $bam);
        my $out_bam = $bam;
        $out_bam =~ s/\.raw\.sorted\.bam$/.recal.sorted.bam/;
        push(@out_bams, $out_bam);
        
        next if -s $out_bam;
        
        my $basename = basename($bam);
        my $job_name = $self->{prefix}.'recalibrate_'.$basename;
        $self->archive_bsub_files($lane_path, $job_name);
        
        # incase we ran without recalibration before, need to delete stat files
        foreach my $suffix ('bas', 'flagstat') {
            unlink($bam.'.'.$suffix);
        }
        
        LSF::run($action_lock, $lane_path, $job_name, $self,
                 qq{perl -MVertRes::Wrapper::GATK -Mstrict -e "VertRes::Wrapper::GATK->new(verbose => $verbose, reference => qq[$self->{reference}], dbsnp => qq[$self->{reference}.rod], build => qq[$build])->recalibrate(qq[$bam], qq[$out_bam]); die qq[recalibration failed for $bam\n] unless -s qq[$out_bam];"});
    }
    
    $self->{bsub_opts} = $orig_bsub_opts;
    return $self->{No};
}

=head2 statistics_requires

 Title   : statistics_requires
 Usage   : my $required_files = $obj->statistics_requires('/path/to/lane');
 Function: Find out what files the statistics action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub statistics_requires {
    my ($self, $lane_path) = @_;
    
    # varies based on if we did recalibration
    my @requires = @{$self->recalibrate_provides($lane_path)};
    
    @requires || $self->throw("Something went wrong; we don't seem to require any bams!");
    
    return \@requires;
}

=head2 statistics_provides

 Title   : statistics_provides
 Usage   : my $provided_files = $obj->statistics_provides('/path/to/lane');
 Function: Find out what files the statistics action generates on
           success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub statistics_provides {
    my ($self, $lane_path) = @_;
    
    my @provides;
    foreach my $bam (@{$self->statistics_requires($lane_path)}) {
        foreach my $suffix ('bas', 'flagstat') {
            push(@provides, $bam.'.'.$suffix);
        }
    }
    
    @provides || $self->throw("Something went wrong; we don't seem to provide any stat files!");
    
    return \@provides;
}

=head2 statistics

 Title   : statistics
 Usage   : $obj->statistics('/path/to/lane', 'lock_filename');
 Function: Creates statistic files for the bam files.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub statistics {
    my ($self, $lane_path, $action_lock) = @_;
    
    # setup filenames etc. we'll use within our temp script
    my $mapper_class = $self->{mapper_class};
    my $verbose = $self->verbose;
    my $release_date = $self->{release_date};
    
    # we treat read 0 (single ended - se) and read1+2 (paired ended - pe)
    # independantly.
    foreach my $bam_file (@{$self->statistics_requires($lane_path)}) {
        my $basename = basename($bam_file);
        $bam_file = $self->{fsu}->catfile($lane_path, $bam_file);
        my $script_name = $self->{fsu}->catfile($lane_path, $self->{prefix}."statistics_$basename.pl");
        
        my @stat_files;
        foreach my $suffix ('bas', 'flagstat') {
            push(@stat_files, $bam_file.'.'.$suffix);
        }
        
        # run this in an LSF call to a temp script
        open(my $scriptfh, '>', $script_name) or $self->throw("Couldn't write to temp script $script_name: $!");
        print $scriptfh qq{
use strict;
use VertRes::Utils::Sam;

my \$sam_util = VertRes::Utils::Sam->new(verbose => $verbose);

my \$num_present = 0;
foreach my \$stat_file (qw(@stat_files)) {
    \$num_present++ if -s \$stat_file;
}
unless (\$num_present == ($#stat_files + 1)) {
    my \$ok = \$sam_util->stats('$release_date', '$bam_file');
    
    unless (\$ok) {
        foreach my \$stat_file (qw(@stat_files)) {
            unlink(\$stat_file);
        }
        die "Failed to get stats for the bam '$bam_file'!\n";
    }
}

exit;
        };
        close $scriptfh;
        
        my $job_name = $self->{prefix}.'statistics_'.$basename;
        $self->archive_bsub_files($lane_path, $job_name);
        
        LSF::run($action_lock, $lane_path, $job_name, $self->{mapper_obj}->_bsub_opts($lane_path, 'statistics'), qq{perl -w $script_name});
    }
    
    return $self->{No};
}

=head2 update_db_requires

 Title   : update_db_requires
 Usage   : my $required_files = $obj->update_db_requires('/path/to/lane');
 Function: Find out what files the update_db action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub update_db_requires {
    my ($self, $lane_path) = @_;
    my @bams = @{$self->statistics_requires($lane_path)};
    my @stats = @{$self->statistics_provides($lane_path)};
    return [@bams, @stats];
}

=head2 update_db_provides

 Title   : update_db_provides
 Usage   : my $provided_files = $obj->update_db_provides('/path/to/lane');
 Function: Find out what files the update_db action generates on success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub update_db_provides {
    return [];
}

=head2 update_db

 Title   : update_db
 Usage   : $obj->update_db('/path/to/lane', 'lock_filename');
 Function: Records in the database that the lane has been mapped, and also store
           some of the mapping stats.
 Returns : $VertRes::Pipeline::Yes or No, depending on if the action completed.
 Args    : lane path, name of lock file to use

=cut

sub update_db {
    my ($self, $lane_path, $action_lock) = @_;
    
    # get the bas files that contain our mapping stats
    my $files = $self->update_db_requires($lane_path);
    my @bas_files;
    foreach my $file (@{$files}) {
        next unless $file =~ /\.bas$/;
        push(@bas_files, $self->{fsu}->catfile($lane_path, $file));
        -s $bas_files[-1] || $self->throw("Expected bas file $bas_files[-1] but it didn't exist!");
    }
    
    @bas_files || $self->throw("There were no bas files!");
    
    my $vrlane = $self->{vrlane};
    my $vrtrack = $vrlane->vrtrack;
    
    return $self->{Yes} if $vrlane->is_processed('mapped');
    
    $vrtrack->transaction_start();
    
    # get the mapping stats from each bas file
    my %stats;
    foreach my $file (@bas_files) {
        my $bp = VertRes::Parser::bas->new(file => $file);
        my $rh = $bp->result_holder;
        my $ok = $bp->next_result; # we'll only ever have one line, since this
                                   # is only one read group
        $ok || $self->throw("bas file '$file' had no entries, suggesting the bam file is empty, which should never happen!");
        
        # We can have up to 2 bas files, one representing single ended mapping,
        # the other paired, so we add where appropriate and only set insert size
        # for the paired
        $stats{raw_reads} += $rh->[9];
        $stats{raw_bases} += $rh->[7];
        $stats{reads_mapped} += $rh->[10];
        $stats{reads_paired} += $rh->[12];
        $stats{bases_mapped} += $rh->[8];
        $stats{mean_insert} = $rh->[15] if $rh->[15];
        $stats{sd_insert} = $rh->[16] if $rh->[15];
    }
    
    $stats{raw_bases} || $self->throw("bas file(s) for $lane_path indicate no raw bases; bam file must be empty, which should never happen!");
    
    # add mapping details to db (overwriting any existing values, but checking
    # existing values so we can work out if we need to update())
    my $mapping = $self->{mapstats_obj};
    my $needs_update = 0;
    foreach my $method (qw(raw_reads raw_bases reads_mapped reads_paired bases_mapped mean_insert sd_insert)) {
        defined $stats{$method} || next;
        my $existing = $mapping->$method;
        if (! defined $existing || $existing != $stats{$method}) {
            $needs_update = 1;
            last;
        }
    }
    if ($needs_update) {
        $mapping->raw_reads($stats{raw_reads});
        $mapping->raw_bases($stats{raw_bases});
        $mapping->reads_mapped($stats{reads_mapped});
        $mapping->reads_paired($stats{reads_paired});
        $mapping->bases_mapped($stats{bases_mapped});
        $mapping->mean_insert($stats{mean_insert}) if $stats{mean_insert};
        $mapping->sd_insert($stats{sd_insert}) if $stats{sd_insert};
        $mapping->update || $self->throw("Unable to set mapping details on lane $lane_path");
    }
    
    # set mapped status
    $vrlane->is_processed('mapped', 1);
    $vrlane->update() || $self->throw("Unable to set mapped status on lane $lane_path");
    
    $vrtrack->transaction_commit();
    
    return $self->{Yes};
}

=head2 cleanup_requires

 Title   : cleanup_requires
 Usage   : my $required_files = $obj->cleanup_requires('/path/to/lane');
 Function: Find out what files the cleanup action needs before it will run.
 Returns : array ref of file names
 Args    : lane path

=cut

sub cleanup_requires {
    return [];
}

=head2 cleanup_provides

 Title   : cleanup_provides
 Usage   : my $provided_files = $obj->cleanup_provides('/path/to/lane');
 Function: Find out what files the cleanup action generates on success.
 Returns : array ref of file names
 Args    : lane path

=cut

sub cleanup_provides {
    return [];
}

=head2 cleanup

 Title   : cleanup
 Usage   : $obj->cleanup('/path/to/lane', 'lock_filename');
 Function: Unlink all the pipeline-related files (_*) in a lane, as well
           as the split directory.
 Returns : $VertRes::Pipeline::Yes
 Args    : lane path, name of lock file to use

=cut

sub cleanup {
    my ($self, $lane_path, $action_lock) = @_;
    return $self->{Yes} unless $self->{do_cleanup};
    
    my $prefix = $self->{prefix};
    
    foreach my $file (qw(log job_status store_nfs
                         split_se split_pe
                         map_se map_pe
                         merge_se merge_pe
                         recalibrate statistics)) {
        
        unlink($self->{fsu}->catfile($lane_path, $prefix.$file));
        
        foreach my $suffix (qw(o e pl)) {
            if ($file =~ /map_([sp]e)/) {
                my $ended = $1;
                $self->_get_read_args($lane_path, $ended) || next;
                my $num_of_splits = $self->_num_of_splits($lane_path, $ended);
                
                foreach my $split (1..$num_of_splits) {
                    my $job_name = $prefix.$file.'_'.$self->{mapstats_id}.'_'.$split;
                    
                    if ($suffix eq 'o') {
                        $self->archive_bsub_files($lane_path, $job_name, 1);
                    }
                    
                    unlink($self->{fsu}->catfile($lane_path, $job_name.'.'.$suffix));
                }
            }
            
            my $job_name;
            if ($file =~ /recalibrate|statistics/) {
                foreach my $ended ('pe', 'se') {
                    foreach my $type ('raw', 'recal') {
                        my $bam = join('.', $ended, $type, 'sorted.bam');
                        
                        $job_name = $prefix.$file.'_'.$self->{mapstats_id}.'.'.$bam;
                        if ($suffix eq 'o') {
                            $self->archive_bsub_files($lane_path, $job_name, 1);
                        }
                        unlink($self->{fsu}->catfile($lane_path, $job_name.'.'.$suffix));
                    }
                }
            }
            else {
                $job_name = $prefix.$file.'_'.$self->{mapstats_id};
                
                if ($suffix eq 'o') {
                    $self->archive_bsub_files($lane_path, $job_name, 1);
                }
                
                unlink($self->{fsu}->catfile($lane_path, $job_name.'.'.$suffix));
            }
        }
    }
    
    unlink($self->{fsu}->catfile($lane_path, 'GATK_Error.log'));
    $self->{fsu}->rmtree($self->{fsu}->catfile($lane_path, 'split_se'.'_'.$self->{mapstats_id}));
    $self->{fsu}->rmtree($self->{fsu}->catfile($lane_path, 'split_pe'.'_'.$self->{mapstats_id}));
    
    return $self->{Yes};
}

sub is_finished {
    my ($self, $lane_path, $action) = @_;
    
    # so that we can delete the split dir(s) at the end of the pipeline, and not
    # redo the map action when it sees there are no split bams
    if ($action->{name} eq 'map') {
        foreach my $ended ('se', 'pe') {
            $self->_get_read_args($lane_path, $ended) || next;
            
            my $done_file = $self->{fsu}->catfile($lane_path, '.mapping_complete_'.$ended.'_'.$self->{mapstats_id});
            
            my $done_bams = 0;
            my $num_of_splits = $self->_num_of_splits($lane_path, $ended);
            my $split_dir = $self->{fsu}->catfile($lane_path, $split_dir_name.'_'.$ended.'_'.$self->{mapstats_id});
            foreach my $split (1..$num_of_splits) {
                $done_bams += (-s $self->{fsu}->catfile($split_dir, $split.'.raw.sorted.bam')) ? 1 : 0;
            }
            
            if (! -e $done_file && $done_bams > 0 && $done_bams == $num_of_splits) {
                system("touch $done_file");
            }
        }
    }
    elsif ($action->{name} eq 'cleanup' || $action->{name} eq 'update_db') {
        return $self->{No};
    }
    elsif ($action->{name} eq 'recalibrate') {
        if ($self->{do_recalibration}) {
            my @raw_bams = @{$self->recalibrate_requires($lane_path)};
            foreach my $bam (@raw_bams) {
                my $bam_file = $self->{fsu}->catfile($lane_path, $bam);
                my $recal_bam = $bam_file;
                $recal_bam =~ s/\.raw\.sorted\.bam$/.recal.sorted.bam/;
                next if $recal_bam eq $bam_file;
                if (-s $recal_bam) {
                    unlink($bam_file);
                    unlink($bam_file.'.bai');
                }
            }
        }
    }
    
    return $self->SUPER::is_finished($lane_path, $action);
}

1;

