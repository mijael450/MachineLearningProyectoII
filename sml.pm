package sml{
   use strict;
   use warnings;
   use Data::Dump qw(dump);
   use List::Util qw(zip min max sum uniq all any shuffle);
   use Tie::IxHash;

   sub add_to_class{
      my($class, $method_name, $code_ref) = @_;

      {
         no strict 'refs';
         no warnings;
         *{$class.'::'.$method_name} = $code_ref;
      }
   }

   sub load_csv{
      my ($self, $file_path, %args) =
      (splice(@_, 0, 2), delimiter => '[,;\t]', @_);

      open (FILE, "<", $file_path)
         or die "Cannot open file $file_path: $!";

      my $header = <FILE>;
      chomp($header);

      my @dataset = ();

      while (<FILE>){
         my $row = $_;

         $row =~ s/[\r\n]+$//g;

         next if (!defined $row || $row =~ /^\s*$/);

         push @dataset,
            [split /$args{delimiter}/, $row];
      }

      close FILE;

      return wantarray
         ? (\@dataset, $header)
         : \@dataset;
   }

   sub str_column_to_float{
      my ($self, $dataset, $column, %args)
         = (splice (@_, 0, 3),
         precision=>1,
         @_);

      return if ($dataset->[0][$column] !~ /^\d+/);

      $args{precision}
         = '%.' . $args{precision} . 'f';

      for my $row (@$dataset){
         $row->[$column]
            = sprintf (
               $args{precision},
               $row->[$column]
            );
      }
   }

   sub str_column_to_int{
      my ($self, $dataset, $column) = @_;

      my $class_values =
         [map {$_->[$column]} @$dataset];

      my @unique = uniq @$class_values;

      my %lookup = ();

      while (my ($i, $value) = each @unique) {
         $lookup{$value} = $i;
      }

      for my $row (@$dataset){
         $row->[$column]
            = $lookup{$row->[$column]};
      }

      return \%lookup;
   }

   sub dataset_minmax{
      my ($self,$dataset)=@_;

      return mx->nd->stack(
         $dataset->min(axis=>0),
         $dataset->max(axis=>0)
      )->transpose();
   }

   sub normalized_dataset{
      my ($self,$dataset,$minmax)=@_;

      my ($min,$max)=@{$minmax->transpose};

      my $slice_cols=
         $dataset->slice_axis(
            axis=>1,
            begin=>0,
            end=>-1
         );

      return ($slice_cols-$min)/($max-$min);
   }

   sub column_means{
      my ($self,$dataset)=@_;

      return mx->nd->mean(
         $dataset,
         axis=>0
      );
   }

   sub column_stdevs{
      my ($self,$dataset,$means)=@_;

      return mx->nd->sqrt(
         ($dataset - $means)
         ->power(2)
         ->sum(axis=>0)
         /($dataset->len -1)
      );
   }

   sub standardize_dataset{
      my ($self,$dataset,$means,$stdevs)=@_;

      return ($dataset-$means) / $stdevs;
   }

   sub train_test_split{
      my ($self, $dataset,%args)
         =(splice(@_,0,2),
         split=>0.6,
         @_);

      my $train_size =
         int($args{split}*$dataset->len);

      my $idx =
         mx->nd->arange(
            stop=>$dataset->len
         )->shuffle;

      my $train_idx =
         $idx->slice_axis(
            axis=>0,
            begin => 0 ,
            end => $train_size
         );

      my $test_idx=
         $idx->slice_axis(
            axis=>0,
            begin => $train_size,
            end=>$dataset->len
         );

      my $train =
         mx->nd->take(
            $dataset,
            $train_idx,
            axis=>0
         );

      my $test =
         mx->nd->take(
            $dataset,
            $test_idx,
            axis=>0
         );

      return $train, $test;
   }

   sub cross_validation_split{
      my ($self, $dataset,%args)
         =(splice(@_,0,2),
         n_folds=>10,
         @_);

      my $dataset_split=[];

      my $fold_size =
         int(
            $dataset->len
            / $args{n_folds}
         );

      my $idx =
         mx->nd->arange(
            stop=>$dataset->len
         )->shuffle;

      for my $i (0 .. $args{n_folds}-1){

         my $fold_idx =
            $idx->slice_axis(
               axis=>0,
               begin=>$i*$fold_size,
               end=>(($i+1)*$fold_size)
            );

         my $fold =
            mx->nd->take(
               $dataset,
               $fold_idx,
               axis=>0
            );

         push @$dataset_split, $fold;
      }

      return $dataset_split;
   }

   1;
}