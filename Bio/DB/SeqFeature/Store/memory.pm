package Bio::DB::SeqFeature::Store::memory;

=head1 NAME

Bio::DB::SeqFeature::Store::memory -- In-memory implementation of Bio::DB::SeqFeature::Store

=head1 SYNOPSIS

  use Bio::DB::SeqFeature::Store;

  # Open the sequence database
  my $db      = Bio::DB::SeqFeature::Store->new( -adaptor => 'memory',
                                                 -dsn     => '/var/databases/test');

  # search... by id
  my @features = $db->fetch_many(@list_of_ids);

  # ...by name
  @features = $db->get_features_by_name('ZK909');

  # ...by alias
  @features = $db->get_features_by_alias('sma-3');

  # ...by type
  @features = $db->get_features_by_name('gene');

  # ...by location
  @features = $db->get_features_by_location(-seq_id=>'Chr1',-start=>4000,-end=>600000);

  # ...by attribute
  @features = $db->get_features_by_attribute({description => 'protein kinase'})

  # ...by the GFF "Note" field
  @result_list = $db->search_notes('kinase');

  # ...by arbitrary combinations of selectors
  @features = $db->features(-name => $name,
                            -type => $types,
                            -seq_id => $seqid,
                            -start  => $start,
                            -end    => $end,
                            -attributes => $attributes);

  # ...using an iterator
  my $iterator = $db->get_seq_stream(-name => $name,
                                     -type => $types,
                                     -seq_id => $seqid,
                                     -start  => $start,
                                     -end    => $end,
                                     -attributes => $attributes);

  while (my $feature = $iterator->next_seq) {
    # do something with the feature
  }

  # ...limiting the search to a particular region
  my $segment  = $db->segment('Chr1',5000=>6000);
  my @features = $segment->features(-type=>['mRNA','match']);

  # getting & storing sequence information
  # Warning: this returns a string, and not a PrimarySeq object
  $db->insert_sequence('Chr1','GATCCCCCGGGATTCCAAAA...');
  my $sequence = $db->fetch_sequence('Chr1',5000=>6000);

  # create a new feature in the database
  my $feature = $db->new_feature(-primary_tag => 'mRNA',
                                 -seq_id      => 'chr3',
                                 -start      => 10000,
                                 -end        => 11000);

=head1 DESCRIPTION

Bio::DB::SeqFeature::Store::memory is the in-memory adaptor for
Bio::DB::SeqFeature::Store. You will not create it directly, but
instead use Bio::DB::SeqFeature::Store->new() to do so.

See L<Bio::DB::SeqFeature::Store> for complete usage instructions.

=head2 Using the memory adaptor

Before using the memory adaptor, populate a readable-directory on the
file system with annotation and sequence files. The annotation files
must be in GFF3 format, and must end in the extension .gff or
.gff3. They may be compressed with "compress", "gzip" or "bzip2" (in
which case the appropriate compression extension will be present as
well.) You may include sequence data inline in the GFF3 files, or put
the sequence data in one or more separate FASTA-format files. These
files must end with .fa or .fasta and may be compressed.

The adaptor store the annotation data in memory, but the sequence data
will be indexed on disk using the Bio::DB::Fasta module. If the
sequence data is included in the GFF3 file, then it will be written
out to a temporary file located in the system TMP directory, indexed,
and removed after the script terminates. Since indexing the temporary
FASTA file is time-consuming, it is more efficient to keep the
sequence in separate FASTA files.

Initialize the database using the -dsn option. This should point to
the directory creating the annotation and sequence files, or to a
single GFF3 file.

=cut

# $Id$
use strict;
use base 'Bio::DB::SeqFeature::Store';
use Bio::DB::SeqFeature::Store::GFF3Loader;
use Bio::DB::GFF::Util::Rearrange 'rearrange';
use File::Temp 'tempdir';
use IO::File;
use Bio::DB::Fasta;

use constant BINSIZE => 10_000;

###
# object initialization
#
sub init {
  my $self          = shift;
  my $args          = shift;
  $self->SUPER::init($args);
  $self->{_data}     = [];
  $self->{_children} = {};
  $self->{_index}    = {};
  $self;
}

sub post_init {
  my $self = shift;
  my ($file_or_dir) = rearrange([['DIR','DSN','FILE']],@_);
  my $loader = Bio::DB::SeqFeature::Store::GFF3Loader->new(-store    => $self,
							   -sf_class => $self->seqfeature_class) 
    or $self->throw("Couldn't create GFF3Loader");
  my @argv;
  if (-d $file_or_dir) {
    @argv = (
	     glob("$file_or_dir/*.gff"),            glob("$file_or_dir/*.gff3"),
	     glob("$file_or_dir/*.gff.{gz,Z,bz2}"), glob("$file_or_dir/*.gff3.{gz,Z,bz2}")
	     );
  } else {
    @argv = $file_or_dir;
  }
  $loader->load(@argv);
  if (my $fh = $self->{fasta_fh}) {
    $fh->close;
    $self->{fasta_db} = Bio::DB::Fasta->new($self->{fasta_file});
  } else {
    $self->{fasta_db} = Bio::DB::Fasta->new($file_or_dir);
  }
}

sub can_store_parentage { 1 }

# return an array ref in which each index is primary id
sub data {
  shift->{_data};
}

sub _store {
  my $self    = shift;
  my $indexed = shift;
  my $data    = $self->data;
  my $count = 0;
  for my $obj (@_) {
    my $primary_id = $obj->primary_id;
    $primary_id    = @{$data} unless defined $primary_id;
    $self->data->[$primary_id] = $obj;
    $obj->primary_id($primary_id);
    $self->{_index}{ids}{$primary_id} = undef if $indexed;
    $self->_update_indexes($obj) if $indexed;
    $count++;
  }
  $count;
}

sub _fetch {
  my $self = shift;
  my $id   = shift;
  my $data = $self->data;
  return $data->[$id];
}

sub _add_SeqFeature {
  my $self = shift;
  my $parent   = shift;
  my @children = @_;
  my $parent_id = (ref $parent ? $parent->primary_id : $parent)
    or $self->throw("$parent should have a primary_id");
  for my $child (@children) {
    my $child_id = ref $child ? $child->primary_id : $child;
    defined $child_id or die "no primary ID known for $child";
    $self->{_children}{$parent_id}{$child_id}++;
  }
}

sub _fetch_SeqFeatures {
  my $self   = shift;
  my $parent = shift;
  my @types  = @_;
  my $parent_id = $parent->primary_id or $self->throw("$parent should have a primary_id");
  my @children_ids  = keys %{$self->{_children}{$parent_id}};
  my @children      = map {$self->fetch($_)} @children_ids;

  if (@types) {
    my $regexp = join '|',map {quotemeta($_)} $self->find_types(@types);
    return grep {($_->primary_tag.':'.$_->source_tag) =~ /^$regexp$/i} @children;
  } else {
    return @children;
  }
}

sub _update_indexes {
  my $self = shift;
  my $obj  = shift;
  defined (my $id   = $obj->primary_id) or return;
  $self->_update_name_index($obj,$id);
  $self->_update_type_index($obj,$id);
  $self->_update_location_index($obj,$id);
  $self->_update_attribute_index($obj,$id);
}

sub _update_name_index {
  my $self = shift;
  my ($obj,$id) = @_;
  my ($names,$aliases) = $self->feature_names($obj);
  foreach (@$names) {
    $self->{_index}{name}{lc $_}{$id} = 1;
  }
  foreach (@$aliases) {
    $self->{_index}{name}{lc $_}{$id} = 2;
  }
}

sub _update_type_index {
  my $self = shift;
  my ($obj,$id) = @_;

  my $primary_tag = $obj->primary_tag;
  my $source_tag  = $obj->source_tag || '';
  return unless defined $primary_tag;

  $primary_tag    .= ":$source_tag";
  $self->{_index}{type}{lc $primary_tag}{$id} = undef;
}

sub _update_location_index {
  my $self = shift;
  my ($obj,$id) = @_;

  my $seq_id      = $obj->seq_id || '';
  my $start       = $obj->start  || '';
  my $end         = $obj->end    || '';
  my $strand      = $obj->strand;
  my $bin_min     = int $start/BINSIZE;
  my $bin_max     = int $end/BINSIZE;

  for (my $bin = $bin_min; $bin <= $bin_max; $bin++ ) {
    $self->{_index}{location}{lc $seq_id}{$bin}{$id} = undef;
  }

}

sub _update_attribute_index {
  my $self = shift;
  my ($obj,$id) = @_;

  for my $tag ($obj->all_tags) {
    for my $value ($obj->each_tag_value($tag)) {
      $self->{_index}{attribute}{lc $tag}{lc $value}{$id} = undef;
    }
  }
}

sub _features {
  my $self = shift;
  my ($seq_id,$start,$end,$strand,
      $name,$class,$allow_aliases,
      $types,
      $attributes,
      $range_type,
      $iterator
     ) = rearrange([['SEQID','SEQ_ID','REF'],'START',['STOP','END'],'STRAND',
		    'NAME','CLASS','ALIASES',
		    ['TYPES','TYPE','PRIMARY_TAG'],
		    ['ATTRIBUTES','ATTRIBUTE'],
		    'RANGE_TYPE',
		    'ITERATOR',
		   ],@_);

  my (@from,@where,@args,@group);
  $range_type ||= 'overlaps';

  my @result;
  unless (defined $name or defined $seq_id or defined $types or defined $attributes) {
    @result = keys %{$self->{_index}{ids}};
  }

  my %found  = ();
  my $result = 1;

  if (defined($name)) {
    # hacky backward compatibility workaround
    undef $class if $class && $class eq 'Sequence';
    $name     = "$class:$name" if defined $class && length $class > 0;
    $result &&= $self->filter_by_name($name,$allow_aliases,\%found);
  }

  if (defined $seq_id) {
    $result &&= $self->filter_by_location($seq_id,$start,$end,$strand,$range_type,\%found);
  }

  if (defined $types) {
    $result &&= $self->filter_by_type($types,\%found);
  }

  if (defined $attributes) {
    $result &&= $self->filter_by_attribute($attributes,\%found);
  }

  push @result,keys %found if $result;
  return $iterator ? Bio::DB::SeqFeature::Store::memory::Iterator->new($self,\@result)
                   : map {$self->fetch($_)} @result;
}


sub filter_by_type {
  my $self = shift;
  my ($types,$filter) = @_;
  my @types = ref $types eq 'ARRAY' ?  @$types : $types;

  my $index = $self->{_index}{type};

  my @types_found = $self->find_types(@types);

  my @results;
  for my $type (@types_found) {
    next unless exists $index->{$type};
    push @results,keys %{$index->{$type}};
  }

  $self->update_filter($filter,\@results);
}

sub find_types {
  my $self = shift;
  my @types = @_;

  my @types_found;
  my $index = $self->{_index}{type};

  for my $type (@types) {

    my ($primary_tag,$source_tag);
    if (ref $type && $type->isa('Bio::DB::GFF::Typename')) {
      $primary_tag = $type->method;
      $source_tag  = $type->source;
    } else {
      ($primary_tag,$source_tag) = split ':',$type,2;
    }
    push @types_found,defined $source_tag ? lc "$primary_tag:$source_tag"
                                          : grep {/^$primary_tag:/i} keys %{$index};
  }
  return @types_found;
}

sub filter_by_attribute {
  my $self = shift;
  my ($attributes,$filter) = @_;

  my $index = $self->{_index}{attribute};
  my $result;

  for my $att_name (keys %$attributes) {
    my @result;
    my @matching_values;
    my @search_terms = ref($attributes->{$att_name}) && ref($attributes->{$att_name}) eq 'ARRAY'
                           ? @{$attributes->{$att_name}} : $attributes->{$att_name};
    my @regexp_terms;
    my @terms;

    for my $v (@search_terms) {
      if (my $regexp = $self->glob_match($v)) {
	@regexp_terms      = keys %{$index->{lc $att_name}} unless @regexp_terms;
	push @terms,grep {/^$v$/i} @regexp_terms;
      } else {
	push @terms,lc $v;
      }
    }

    for my $v (@terms) {
      push @result,keys %{$index->{lc $att_name}{$v}};
    }

    $result ||= $self->update_filter($filter,\@result);
  }

  $result;
}

sub filter_by_location {
  my $self = shift;
  my ($seq_id,$start,$end,$strand,$range_type,$filter) = @_;
  $strand ||= 0;

  my $index = $self->{_index}{location}{lc $seq_id};
  my @bins;

  if (!defined $start or !defined $end or $range_type eq 'contained_in') {
    @bins = sort {$a<=>$b} keys %{$index};
    # be suspicious of this -- possibly a fencepost error at $end
    $start = $bins[0]  * BINSIZE  unless defined $start;
    $end   = $bins[-1] * BINSIZE  unless defined $end;
  }
  my %seenit;
  my $bin_min       = int $start/BINSIZE;
  my $bin_max       = int $end/BINSIZE;
  my @bins_in_range = $range_type eq 'contained_in' ? ($bins[0]..$bin_min,$bin_max..$bins[-1])
                                                    : ($bin_min..$bin_max);

  my @results;
  for my $bin (@bins_in_range) {
    next unless exists $index->{$bin};
    my @found = keys %{$index->{$bin}};
    for my $f (@found) {
      next if $seenit{$f}++;
      my $feature = $self->_fetch($f) or next;
      next if $strand && $feature->strand != $strand;

      if ($range_type eq 'overlaps') {
	next unless $feature->end >= $start && $feature->start <= $end;
      }
      elsif ($range_type eq 'contains') {
	next unless $feature->start >= $start && $feature->end <= $end;
      }
      elsif ($range_type eq 'contained_in') {
	next unless $feature->start <= $start && $feature->end >= $end;
      }

      push @results,$f;
    }
  }
  $self->update_filter($filter,\@results);
}


sub filter_by_name {
  my $self = shift;
  my ($name,$allow_aliases,$filter) = @_;

  my $index = $self->{_index}{name};

  my @names_to_fetch;
  if (my $regexp = $self->glob_match($name)) {
    @names_to_fetch = grep {/^$regexp$/i} keys %{$index};
  } else {
    @names_to_fetch = lc $name;
  }

  my @results;
  for my $n (@names_to_fetch) {
    if ($allow_aliases) {
      push @results,keys %{$index->{$n}};
    } else {
      push @results,grep {$index->{$n}{$_} == 1} keys %{$index->{$n}};
    }
  }
  $self->update_filter($filter,\@results);
}

sub glob_match {
  my $self = shift;
  my $term = shift;
  return unless $term =~ /(?:^|[^\\])[*?]/;
  $term =~ s/(^|[^\\])([+\[\]^{}\$|\(\).])/$1\\$2/g;
  $term =~ s/(^|[^\\])\*/$1.*/g;
  $term =~ s/(^|[^\\])\?/$1./g;
  return $term;
}


sub update_filter {
  my $self = shift;
  my ($filter,$results) = @_;
  return unless @$results;

  if (%$filter) {
    my @filtered = grep {$filter->{$_}} @$results;
    %$filter     = map {$_=>1} @filtered;
  } else {
    %$filter     = map {$_=>1} @$results;
  }

}

sub _search_attributes {
  my $self = shift;
  my ($search_string,$attribute_array,$limit) = @_;

  $search_string =~ tr/*?//d;

  my @words = map {quotemeta($_)} $search_string =~ /(\w+)/g;
  my $search = join '|',@words;

  my (%results,%notes);

  my $index  = $self->{_index}{attribute};
  for my $tag (@$attribute_array) {
    my $attributes = $index->{lc $tag};
    for my $value (keys %{$attributes}) {
      next unless $value =~ /$search/i;
      my @ids = keys %{$attributes->{$value}};
      for my $w (@words) {
	my @hits = $value =~ /($w)/ig or next;
	$results{$_} += @hits foreach @ids;
      }
      $notes{$_} .= "$value " foreach @ids;
    }
  }

  my @results;
  for my $id (keys %results) {
    my $hits = $results{$id};
    my $note = $notes{$id};
    $note =~ s/\s+$//;
    my $relevance = 10 * $hits;
    my $feature   = $self->fetch($id);
    my $name      = $feature->display_name or next;
    push @results,[$name,$note,$relevance];
  }

  return @results;
}


# this is ugly
sub _insert_sequence {
  my $self = shift;
  my ($seqid,$seq,$offset) = @_;
  my $dna_fh = $self->private_fasta_file or return;
  if ($offset == 0) { # start of the sequence
    print $dna_fh ">$seqid\n";
  }
  print $dna_fh $seq,"\n";
}

sub _fetch_sequence {
  my $self = shift;
  my ($seqid,$start,$end) = @_;
  my $db = $self->{fasta_db} or return;
  $db->seq($seqid,$start,$end);
}

sub private_fasta_file {
  my $self = shift;
  return $self->{fasta_fh} if exists $self->{fasta_fh};
  my $dir = tempdir (CLEANUP => 1);
  $self->{fasta_file}   = "$dir/sequence.$$.fasta";
  return $self->{fasta_fh} = IO::File->new($self->{fasta_file},">");
}

package Bio::DB::SeqFeature::Store::memory::Iterator;

sub new {
  my $class = shift;
  my $store = shift;
  my $ids   = shift;
  return bless {store => $store,
		ids   => $ids},ref($class) || $class;
}

sub next_seq {
  my $self  = shift;
  my $store = $self->{store} or return;
  my $id    = shift @{$self->{ids}};
  defined $id or return;
  return $store->fetch($id);
}

1;