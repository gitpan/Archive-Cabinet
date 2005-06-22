package Archive::Cabinet;

use 5.008005;
use strict;
use warnings;

require Exporter;
require DynaLoader;

our @ISA = qw(Exporter DynaLoader);

our $VERSION = '0.01';

require XSLoader;
XSLoader::load('Archive::Cabinet', $VERSION);

# All the magic is in Cabinet.xs


1;
__END__
=head1 NAME

Archive::Cabinet - Perl extension for libmspack

=head1 SYNOPSIS

  use Archive::Cabinet;

  my $cab = Archive::Cabinet->new("mycab.cab") or die "Couldn't open CAB.\n";
  my $href = $cab->get_file_attributes;
  foreach my $filename ( keys %{ $href } ) {
    print "$filename size: ", $href->{$filename}->{size}, "\n";
    my $buffer=$cab->extract($filename);
    # Do something interesting with $buffer here.
  }
  $cab->close; # Highly recommended.

=head1 DESCRIPTION
 
Archive::Cabinet is a Perl interface to Stuart Caie's current implementation of
C<libmspack>, a C library which (currently only) unpacks Microsoft Cabinet or
"CAB" files.  libmspack can extract CABs even when they're embedded inside
other MS filetypes such as "EXE", "DLL" and others.

Note: C<libmspack> does NOT unpack InstallShield CAB files, and so neither
does this Perl module. InstallShield CABs use a different 
encoding/compression algorithm than Microsoft's CAB formats.

=head2 Methods

=over 4

=item C<new([cabfile])>

Method constructor. Optionally takes the name of a cabfile to open(). 

=item C<open(cabfile)>

Searches the specified cabfile for CAB formatted data. The CAB may be embedded
within some other file. Returns an opened cab object on success, otherwise, 
returns undef.

=item C<close>

Method destructor. Frees all allocated memory structures. 

It is B<highly recommended> that you explicitly close any open CABs when you 
are finished processing them. Do not depend on your variables falling out 
of scope to free memory (although this usually works anyway.) 

=item C<list_files>

Returns an array of file names inside an opened CAB file.

=item C<get_file_attributes>

Returns a hashref to a hash of hashes. The top hash is organized with 
keys of the filenames contained within the open CAB. The corresponding 
values to the filename keys are anonymous hashes with keys of:

  * date (value is a scalar string; format: MM-DD-YYYY, zero padded)
  * time (value is a scalar string; format: HH:MM:SS, zero padded)
  * size (value is a scalar integer)

which reflect the creation date, creation time, and size of the 
uncompressed data.  

=item C<extract(filename)>

On success, returns a scalar with the contents of the specified filename, 
otherwise it returns undef on error conditions.

=item C<extract_all>

Writes all files in the CAB to their specified filenames to the current
working directory. Returns 1 if successful, otherwise 0.

=item C<extract_to_file(filename, target)>

Writes the contents of the filename specified to the target file. Returns
1 if successful, otherwise 0.

=back

=head1 NOTES

You'll need to download, compile and install C<libmspack> to use this
module (because it implements all the heavy lifting.) You can get a copy 
of library source code by visiting the URL below.

This module expects to link against C<libmspack>, which is installed 
by the distribution tarball in /usr/local/bin.  This path may or may not 
be in your ldconfig path. If not, you will probably have to add that path
to your system's ld.so.conf file.

We've only used and tested this module on 32 bit Intel Linux. 

=head1 SEE ALSO

libmspack L<http://www.kyz.uklinux.net/libmspack/>

=head1 AUTHOR

Brad Douglas, E<lt>rez@touchofmadness.comE<gt>

Mark Allen, E<lt>mrallen1@yahoo.comE<gt>

=head1 VERSION

Version 1.10

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005 by Brad Douglas

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
