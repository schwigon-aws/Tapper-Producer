## no critic (RequireUseStrict)
package Tapper::Producer::Builder;
# ABSTRACT: produce preconditions from external OSRC builder

        use Moose;
        use parent "Tapper::Base";
        use Net::SSH::Perl;
        use Tapper::Config;
        use YAML;
        use autodie;

        use 5.010;

        has cfg => (isa => 'HashRef', is => 'ro', default => sub {Tapper::Config->subconfig});

=head1 SYNOPSIS

Tapper::Producer::Builder is a producer for Tapper (you probably guessed
this).  This means it substitutes its own precondition with number of
new ones, in this case a package precondition.

 use Tapper::Producer::Builder;
 my $builder = Tapper::Producer::Builder->new();
 $builder->produce($job, {type => 'kernel',
                          buildserver => 'hostname',
                          repository => 'linus',
                          version => 'HEAD'});

A typical precondition to trigger this producer in Tapper might look
like this:

  precondition_type: produce
  producer: Builder
  type: xen            # required
  buildserver: host    # required
  repository: xen-3.4  # required
  version: HEAD^1      # optional, defaults to HEAD
  patches:             # optional
  - /path/to/first/patchfile
  - /path/to/second/patchfile

=head1 FUNCTIONS

=head2 produce

Call the given build server to get a new package and return a new
package precondition.
The following options are recognised in the producer precondition:
* type - string - one of xen, kernel (required)
* buildserver - string - hostname of the build server (required)
* repository  - string - the name of a repository as understood by the buildserver (required)
* version     - string - a version string for the repository as understood by the buildserver (optional)
* patches     - array of string - filenames of patch files, need to be available to build server (optional)

@param Job object - the job we build a package for
@param hash ref   - producer precondition

@return success - hash ref containing list of new preconditions

@throws die();

=cut

        sub produce {
                my ($self, $job, $produce) = @_;

                unless ($job && $job->can('testrun_id')) { die "Parameter 'job' does not provide testrun_id" }
                my $type = $produce->{type} // '';
                my $host = $produce->{buildserver} || die "Missing required parameter 'buildserver'";
                my $repo = $produce->{repository}  || die "Missing required parameter 'repository'";
                my $rev  = $produce->{version}     || 'HEAD';
                my $patches = $produce->{patches}  || [];
                my $cmd;
                my $new_precondition = [];

                given($type) {
                        when('kernel') { $cmd = 'build_kernel.sh' };
                        when('xen')    { $cmd = 'xenbuild.sh' };
                        default        { die "Unknown build type '$type'"};
                }

                my $ssh = Net::SSH::Perl->new($host, user => "root", protocol => 2 );
                $ssh->login('root','');

                $cmd .=" $repo $rev ";
                if (ref $patches eq 'ARRAY'){
                        $cmd .= join " ", @$patches;
                }

                my($stdout, $stderr, $exit) = $ssh->cmd("NOSCHED=1 $cmd");

                my $path = $self->cfg->{paths}{output_dir};
                my $testrun_id = $job->testrun_id();
                $path .= "/$testrun_id/config/builder/";
                $self->makedir($path);

                my $filename = "$path/${type}_${host}_${repo}_${rev}";
                my $prefix   = "\n\n\t\tNext build".("="x80)."\n\n";
                open(my $fh_stdout, ">>", $filename.".stdout");
                open(my $fh_stderr, ">>", $filename.".stderr");

                # append output after that of other builder producers
                print $fh_stdout $prefix if -s $filename.".stdout";
                print $fh_stderr $prefix if -s $filename.".stderr";

                {
                        # don't care whether build server provided stdout or stderr
                        no warnings 'uninitialized';
                        print $fh_stdout "Patch files: ", join(" ", @$patches) if @$patches;
                        print $fh_stdout $stdout;
                        print $fh_stderr $stderr;
                }

                if (my ($output) = $stdout =~ m/(?:\n|^)---\n(.+\n)\.\.\./s ) {
                        my $yaml = YAML::Load($output);
                        foreach my $package_name (@$yaml) {
                                push @$new_precondition, {precondition_type => 'package', filename => $package_name};
                        }
                } else {
                        die "Build server did not provide a package file name";
                }

                return {precondition_yaml => YAML::Dump(@$new_precondition)};
        }

1;
