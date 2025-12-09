#!/bin/bash
# Revision: $Revision: 1.81 $

set -e

if [ X"$(id -u)" = X0 ]; then
  echo "*** CMS SOFTWARE INSTALLATION ABORTED ***" 1>&2
  echo "CMS software cannot be installed as the super-user." 1>&2
  echo "(We recommend reading any standard unix security guide.)" 1>&2
  exit 1
fi

if [ "X`printf hasprintf 2>/dev/null`" = Xhasprintf ]; then
  echo_n() { printf "%s" ${1+"$@"}; }
elif [ "X`echo -n`" = "X-n" ]; then
  echo_n() { echo ${1+"$@"}"\c"; }
else
  echo_n() { echo -n ${1+"$@"}; }
fi

get_cmsos() {
  echo $cmsarch
}
cleanup_and_exit () {
    exitcode=$1
    exitmessage=$2
    [ "X$exitmessage" = X ] || { echo && echo $exitmessage 1>&2; }
    [ "X$debug" = Xtrue ] && exit $exitcode
    [ "X$tempdir" = X ] || [ -d $tempdir ] && rm -rf $tempdir
    [ "X$DOWNLOAD_DIR" = X ] || [ -d $DOWNLOAD_DIR ] && rm -rf $DOWNLOAD_DIR
    [ "X$importTmp" = X ] || [ -d $importTmp ] && rm -rf $importTmp
    exit $exitcode 
}

download_method=
download_curl () { curl -L -f -H "Cache-Control: max-age=0" --user-agent "CMSPKG/1.0" --connect-timeout 60 --max-time 600 -q -s "$1" -o "$2.tmp" && mv "$2.tmp" "$2"; }
download_wget () { wget --no-check-certificate --header="Cache-Control: max-age=0" --user-agent="CMSPKG/1.0" --timeout=600 -q -O "$2.tmp" "$1" 2>/dev/null && mv "$2.tmp" "$2"; }
download_none () { cleanup_and_exit 1 "No curl or wget, cannot fetch $1" 
}

# Figure out how to download stuff
if [ -z "$download_method" ]; then
  if [ `wget --version 2>/dev/null | wc -l` != 0 ]; then
    download_method=wget
  elif [ `curl --version 2>/dev/null | wc -l` != 0 ]; then
    download_method=curl
  else
    download_method=none
  fi
fi

# Safely create a user-specific temp directory.
# We look for TMPDIR since /tmp might not be user
# writeable.
# Notice that -p option does not work on MacOSX and
# ${${TMPDIR:-/tmp}} is zsh only.
if [ "X$TMPDIR" = X ]
then
  tempdir=`mktemp -d /tmp/tmpXXXXX`
else
  tempdir=`mktemp -d $TMPDIR/tmpXXXXX`
fi

# We have our own version of find-provides for bootstrap, so that we don't
# depend on a "system" rpm installation. This is particularly handy in the case 
# of macosx and other unsupported distributions which don't use rpm as a 
# package manager (e.g. ubuntu).
rpmFindProvides=$tempdir/my-find-provides
cat > $rpmFindProvides <<\EOF_FIND_PROVIDES
#!/bin/bash

# This script reads filenames from STDIN and outputs any relevant provides
# information that needs to be included in the package.

filelist=`sed "s/['\"]/\\\&/g"`

solist=$(echo $filelist | grep "\\.so" | grep -v "^/lib/ld.so" | \
        xargs file -L 2>/dev/null | grep "ELF.*shared object" | cut -d: -f1)
pythonlist=
tcllist=

#
# --- Alpha does not mark 64bit dependencies
case `uname -m` in
  alpha*)       mark64="" ;;
  *)            mark64="()(64bit)" ;;
esac

#
# --- Library sonames and weak symbol versions (from glibc).
for f in $solist; do
    soname=$(objdump -p $f | awk '/SONAME/ {print $2}')

    lib64=`if file -L $f 2>/dev/null | \
        grep "ELF 64-bit" >/dev/null; then echo "$mark64"; fi`
    if [ "$soname" != "" ]; then
        if [ ! -L $f ]; then
            echo $soname$lib64
            objdump -p $f | awk '
                BEGIN { START=0 ; }
                /Version definitions:/ { START=1; }
                /^[0-9]/ && (START==1) { print $4; }
                /^$/ { START=0; }
            ' | \
                grep -v $soname | \
                while read symbol ; do
                    echo "$soname($symbol)`echo $lib64 | sed 's/()//'`"
                done
        fi
    else
        echo ${f##*/}$lib64
    fi
done | sort -u

#
# --- Perl modules.
[ -x /usr/lib/rpm/perl.prov ] &&
    echo $filelist | tr '[:blank:]' \\n | grep '\.pm$' | /usr/lib/rpm/perl.prov | sort -u

#
# --- Python modules.
[ -x /usr/lib/rpm/python.prov -a -n "$pythonlist" ] &&
    echo $pythonlist | tr '[:blank:]' \\n | /usr/lib/rpm/python.prov | sort -u

#
# --- Tcl modules.
[ -x /usr/lib/rpm/tcl.prov -a -n "$tcllist" ] &&
    echo $tcllist | tr '[:blank:]' \\n | /usr/lib/rpm/tcl.prov | sort -u

exit 0
EOF_FIND_PROVIDES

mkdir -p $tempdir/lib/perl5/site_perl/RPM/Header/PurePerl
mkdir -p $tempdir/bin

cat << \EOF_RPM_HEADER_PUREPERL_PM > $tempdir/lib/perl5/site_perl/RPM/Header/PurePerl.pm
# Copyright (C) 2001,2002,2006 Troels Liebe Bentsen
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package RPM::Header::PurePerl;
use vars '$VERSION';
$VERSION = q{1.0.2};

use strict;
use RPM::Header::PurePerl::Tagtable;

sub TIEHASH   # during tie()
{
    my $RPM_HEADER_MAGIC = chr(0x8e).chr(0xad).chr(0xe8);
    my $RPM_FILE_MAGIC   = chr(0xed).chr(0xab).chr(0xee).chr(0xdb);
    my $buff;
    
    my ($class_name, $filename, $readtype) = @_;
    my $self = bless { hash => {}, }, $class_name;
    
    if (!defined($filename) or !open(RPMFILE, "<$filename")) { return undef; }
    
    binmode(RPMFILE);
    
    # Read rpm lead
    read(RPMFILE, $buff, 96);
    ( $self->{'hash'}->{'LEAD_MAGIC'},          # unsigned char[4], í«îÛ == rpm
      $self->{'hash'}->{'LEAD_MAJOR'},          # unsigned char, 3 == rpm version 3.x
      $self->{'hash'}->{'LEAD_MINOR'},          # unsigned char, 0 == rpm version x.0
      $self->{'hash'}->{'LEAD_TYPE'},           # short(int16), 0 == binary, 1 == source
      $self->{'hash'}->{'LEAD_ARCHNUM'},        # short(int16), 1 == i386
      $self->{'hash'}->{'LEAD_NAME'},           # char[66], rpm name
      $self->{'hash'}->{'LEAD_OSNUM'},          # short(int16), 1 == Linux
      $self->{'hash'}->{'LEAD_SIGNATURETYPE'},  # short(int16), 1280 == rpm 4.0
      $self->{'hash'}->{'LEAD_RESERVED'}        # char[16] future expansion
    ) = unpack("a4CCssA66ssA16", $buff);
    # DEBUG:
    # foreach my $var (keys %{$self->{'hash'}}) { print "$self->{'hash'}->{$var}\n"; } exit;
    
    if (!$self->{'hash'}->{'LEAD_MAGIC'} eq $RPM_FILE_MAGIC) { return 0; }
    
    # Quick read option.
    if (defined($readtype) and ($readtype eq 'onlylead')) { return $self; }
    
    for (my $header_num=1; $header_num < 3; $header_num++) {
        # DEBUG:
        # print "hlead:".tell(RPMFILE)."\n";
        
        # Read lead of the headers
        read(RPMFILE, $buff, 16);
        
        # DEBUG:
        # print "hlead:".tell(RPMFILE)."\n";
        
        my ($header_magic, $header_version, $header_reserved, $header_entries, 
            $header_size) = unpack("a3CNNN", $buff);
        
        # DEBUG:
        #print "$header_magic, $header_version, $header_reserved, $header_entries, $header_size\n"; next;
        #read(RPMFILE, $buff, 2200, 0); print "header magic:".index($buff, $RPM_HEADER_MAGIC, 256)."\n"; exit;  
        
        if ($header_magic eq $RPM_HEADER_MAGIC) { # RPM_HEADER_MAGIC
            # Read the record structure.
            my $record;
            read(RPMFILE, $record, 16*$header_entries); 
                
            # Read the tag structure, pad to a multiplyer of 8 if it's the first header.
            if ($header_num == 1) {
                # DEBUG:
                #print "Offset 1: $header_size, ".tell(RPMFILE)."\n";
                if (($header_size % 8) == 0) {
                    read(RPMFILE, $buff, $header_size);
                }
                else {
                    read(RPMFILE, $buff, $header_size+(8-($header_size % 8)));
                }
            } 
            else {
                # DEBUG:
                #print "Offset 2:".tell(RPMFILE)."\n";
                read(RPMFILE, $buff, $header_size);
            }
            
            for (my $record_num=0; $record_num < $header_entries; 
                $record_num++) { # RECORD LOOP
                my ($tag, $type, $offset, $count) = 
                    unpack("NNNN", substr($record, $record_num*16, 16));
                
                my @value;
                
                # 10x if signature header.
                if ($header_num == 1) { $tag = $tag*10; }
                    
                # Unknown tag
                if (!defined($hdr_tags{$tag})) { 
                    print "Unknown $tag, $type\n"; next; 
                }
                # Null type
                elsif ($type == 0) { 
                    @value = ('');
                }
                # Char type
                elsif ($type == 1) {
                    print "Char $count $hdr_tags{$tag}{'TAGNAME'}\n";
                    #for (my $i=0; $i < $count; $i++) {
                    #push(@value, substr($buff, $offset, $count));
                    #   $header_info{$record}{'offset'} += $count;
                    #}
                }
                # int8
                elsif ($type == 2) { 
                    @value = unpack("C*", substr($buff, $offset, 1*$count)); 
                    $offset = 1*$count;
                }
                # int16
                elsif ($type == 3) { 
                    @value = unpack("n*", substr($buff, $offset, 2*$count)); 
                    $offset = 2*$count;
                }                
                    # int32
                elsif ($type == 4) { 
                    @value = unpack("N*", substr($buff, $offset, 4*$count)); 
                    $offset = 4*$count;
                }                
                # int64
                elsif ($type == 5) { 
                    print "Int64(Not supported): ".
                        "$count $hdr_tags{$tag}{'TAGNAME'}\n";
                    #@value = unpack("N*", substr($buff, $offset, 4*$count)); 
                    #$offset = 4*$count;
                }
                # String, String array, I18N string array
                if ($type == 6 or $type == 8 or $type == 9) {
                    for(my $i=0;$i<$count;$i++) {
                        my $length = index($buff, "\0", $offset)-$offset;
                        # unpack istedet for substr.
                        push(@value, substr($buff, $offset, $length));
                        $offset += $length+1;
                    }
                } 
                # bin
                elsif ($type == 7) { 
                    #print "Bin $count $tags{$tag}{'TAGNAME'}\n";
                    $value[0] = substr($buff, $offset, $count);
                }
                # Find out if it's an array type or not.
                if (defined($hdr_tags{$tag}{'TYPE'}) 
                        and $hdr_tags{$tag}{'TYPE'} == 1) {
                    @{$self->{'hash'}->{$hdr_tags{$tag}{'TAGNAME'}}} = @value;
                }
                else {
                    $self->{'hash'}->{$hdr_tags{$tag}{'TAGNAME'}} = $value[0];
                }
            } # RECORD LOOP 
        } # HEADER LOOP
    }
    
    # Save package(cpio.gz) location.
    $self->{'hash'}->{'PACKAGE_OFFSET'} = tell(RPMFILE);
    close(RPMFILE);

    # Make old packages look like new ones.
    if (defined($self->{'hash'}->{'FILENAMES'})) {
        my $count = 0;
        my %quick_dirnames;
        foreach my $filename (@{$self->{'hash'}->{'FILENAMES'}}) {
            my $file = ''; my $dir = '/';
            
            if($filename =~ /(.*\/)(.*$)/) { 
                $file = $1; $dir = $2; 
            } else { 
                $file = $filename; 
            }
            
            if (!defined($quick_dirnames{$dir})) {
                push(@{$self->{'hash'}->{'DIRNAMES'}}, $dir);
                $quick_dirnames{$dir} = $count++;
            }
            push(@{$self->{'hash'}->{'BASENAMES'}}, $file);
            push(@{$self->{'hash'}->{'DIRINDEXES'}}, $quick_dirnames{$dir});
        }
        delete($self->{'hash'}->{'FILENAMES'});
    }

    # Wait I can beat it, a package sould also provide is's own name, sish (and only once). 
    my %quick_provides = map {$_ => 1} @{$self->{'hash'}->{'PROVIDENAME'}};
    my %quick_provideflags = map {$_ => 1} @{$self->{'hash'}->{'PROVIDEFLAGS'}};
    my %quick_provideversion 
        = map {$_ => 1} @{$self->{'hash'}->{'PROVIDEVERSION'}};
        
    if (!defined($quick_provides{$self->{'hash'}->{'NAME'}}) and 
        !defined($quick_provideflags{8}) and 
        !defined($quick_provideversion{$self->{'hash'}->{'VERSION'}})) {
        push(@{$self->{'hash'}->{'PROVIDENAME'}}, $self->{'hash'}->{'NAME'});
        push(@{$self->{'hash'}->{'PROVIDEFLAGS'}}, 8);
        push(@{$self->{'hash'}->{'PROVIDEVERSION'}}, 
            $self->{'hash'}->{'VERSION'}.'-'.$self->{'hash'}->{'RELEASE'});
    }
    
    # FILEVERIFYFLAGS is signed
    if ($self->{'hash'}->{'FILEVERIFYFLAGS'}) {
        for(my $i=0;$i<int(@{$self->{'hash'}->{'FILEVERIFYFLAGS'}}); $i++) {
            my $val = @{$self->{'hash'}->{'FILEVERIFYFLAGS'}}[$i];
            if (int($val) == $val && $val >= 2147483648 && 
                $val <= 4294967295) { 
                @{$self->{'hash'}->{'FILEVERIFYFLAGS'}}[$i] -= 4294967296;
            }
        }
    }
        
    # Lets handel the SIGNATURE, this does not work, fix it please.
    if (defined($self->{'hash'}->{'SIGNATURE_MD5'})) {
        $self->{'hash'}->{'SIGNATURE_MD5'} = 
            unpack("H*", $self->{'hash'}->{'SIGNATURE_MD5'});
    }

    # Old stuff, so it can be a drop in replacement for RPM::HEADERS.
    if (defined($self->{'hash'}->{'EPOCH'})) {
        $self->{'hash'}->{'SERIAL'} = $self->{'hash'}->{'EPOCH'};
    }

    if (defined($self->{'hash'}->{'LICENSE'})) {
        $self->{'hash'}->{'COPYRIGHT'} = $self->{'hash'}->{'LICENSE'};
    }
    
    if (defined($self->{'hash'}->{'PROVIDENAME'})) {
        $self->{'hash'}->{'PROVIDES'} = $self->{'hash'}->{'PROVIDENAME'};
    }
    
    if (defined($self->{'hash'}->{'OBSOLETENAME'})) {
        $self->{'hash'}->{'OBSOLETES'} = $self->{'hash'}->{'OBSOLETENAME'};
    }
    
    return $self;
}

sub FETCH     # during $a = $ht{something};
{
    my ($self, $key) = @_;
    return $self->{hash}->{$key};
}

sub STORE     # during $ht{something} = $a;
{
    my ($self, $key, $val) = @_;
    $self->{hash}->{$key} = $val;
}

sub DELETE    # during delete $ht{something}
{
    my ($self, $key) = @_;
    delete $self->{hash}->{$key};
}

sub CLEAR     # during %h = ();
{
    my ($self) = @_;
    $self->{hash} = {};
    ();
}

sub EXISTS    # during if (exists $h{something}) { ... }
{
    my ($self, $key) = @_;
    return exists $self->{hash}->{$key};
}

sub FIRSTKEY  # at the beginning of foreach (keys %h) { ... }
{
    my ($self) = @_;
    each %{$self->{hash}};
}

sub NEXTKEY   # during foreach()
{
    my ($self) = @_;
    each %{$self->{hash}};
}

sub DESTROY   # well, when the hash gets destroyed
{
    # do nothing here
}

=head1 NAME

RPM::Header::PurePerl - a perl only implementation of a RPM header reader.

=head1 VERSION

Version 1.0.2

=head1 SYNOPSIS

    use RPM::Header::PurePerl;
    tie my %rpm, "RPM::Header::PurePerl", "rpm-4.0-1-i586.rpm" 
        or die "Problem, could not open rpm";
    print $rpm{'NAME'};

=head1 DESCRIPTION

RPM::Header::PurePerl is a clone of RPM::Header written in only Perl, so it 
provides a way to read a rpm package on systems where rpm is not installed.
RPM::Header::PurePerl can used as a drop in replacement for RPM::Header, if
needed also the other way round.

=head1 NOTES

The former name of this package was RPM::PerlOnly.

=head1 AUTHOR

Troels Liebe Bentsen <tlb@rapanden.dk>

=head1 COPYRIGHT AND LICENCE

Copyright (C) 2001,2002,2006 Troels Liebe Bentsen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
__END__

EOF_RPM_HEADER_PUREPERL_PM

cat << \EOF_RPM_HEADER_PUREPERL_TAGSTABLE_PM > $tempdir/lib/perl5/site_perl/RPM/Header/PurePerl/Tagtable.pm
package RPM::Header::PurePerl::Tagtable;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
use vars qw(%hdr_tags);
@EXPORT = qw(%hdr_tags);

%hdr_tags = 
(
	63 =>	{
	 	'TAGNAME'	=>	'UNKNOWN1',
		'GROUP'		=>	'UNKNOWN',
		'NAME'		=>	''
	},
	
	620 =>	{
	 	'TAGNAME'	=>	'UNKNOWN2',
		'GROUP'		=>	'UNKNOWN',
		'NAME'		=>	''
	},

	
	2650 =>	{
	 	'TAGNAME'	=>	'SHA1HEADER1',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},	
	
	2670 =>	{
	 	'TAGNAME'	=>	'UNKNOWN3',
		'GROUP'		=>	'UNKNOWN',
		'NAME'		=>	''
	},	
	
	2690 =>	{
	 	'TAGNAME'	=>	'SHA1HEADER',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	
	
	
	100 =>	{
	 	'TAGNAME'	=>	'DESCRIPTIONLANGS',
		'GROUP'		=>	'DESCRIPTIONLANGS',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	 
	1000 => {
		'TAGNAME'	=>	'NAME',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Name'
	},
	1001 => {
		'TAGNAME'	=>	'VERSION',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Version'
	},
	1002 => {
		'TAGNAME'	=>	'RELEASE',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Release'
	},
	1003 => {
		'TAGNAME'	=>	'EPOCH',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Epoch do something with me'
	},
	1004 => {
		'TAGNAME'	=>	'SUMMARY',
		'GROUP'		=>	'DESCRIPTION',
		'NAME'		=>	'Summary',
		'TYPE'		=>	1
	},
	1005 => {
		'TAGNAME'	=>	'DESCRIPTION',
		'GROUP'		=>	'DESCRIPTION',
		'NAME'		=>	'Description',
		'TYPE'		=>	1
	},
	1006 => {
		'TAGNAME'	=>	'BUILDTIME',
		'GROUP'		=>	'PACKAGE',
		'NAME'		=>	'BuildTime'
	},
	1007 => {
		'TAGNAME'	=>	'BUILDHOST',
		'GROUP'		=>	'PACKAGE',
		'NAME'		=>	'BuildHost'
	},
	1008 => {
		'TAGNAME'	=>	'INSTALLTIME',
		'GROUP'		=>	'PACKAGE',
		'NAME'		=>	'InstallTime'
	},
	1009 => {
		'TAGNAME'	=>	'SIZE',
		'GROUP'		=>	'PACKAGE',
		'NAME'		=>	'Size'
	},
	1010 => {
		'TAGNAME'	=>	'DISTRIBUTION',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Distribution'
	},
	1011 => {
		'TAGNAME'	=>	'VENDOR',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Vendor'
	},
	1012 => {
		'TAGNAME'	=>	'GIF',
		'GROUP'		=>	'BINARY',
		'NAME'		=>	''
	},
	1013 => {
		'TAGNAME'	=>	'XPM',
		'GROUP'		=>	'BINARY',
		'NAME'		=>	''
	},
	1014 => {
		'TAGNAME'	=>	'LICENSE',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'License'
	},
	1015 => {
		'TAGNAME'	=>	'PACKAGER',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Packager'
	},
	1016 => {
		'TAGNAME'	=>	'GROUP',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Location'
	},
	1018 => {
		'TAGNAME'	=>	'SOURCE',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1019 => {
		'TAGNAME'	=>	'PATCH',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1020 => {
		'TAGNAME'	=>	'URL',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'URL'
	},
	1021 => {
		'TAGNAME'	=>	'OS',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Os'
	},
	1022 => {
		'TAGNAME'	=>	'ARCH',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'Arch'
	},
	1023 => {
		'TAGNAME'	=>	'PREIN',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1024 => {
		'TAGNAME'	=>	'POSTIN',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1025 => {
		'TAGNAME'	=>	'PREUN',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1026 => {
		'TAGNAME'	=>	'POSTUN',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1027 => {
		'TAGNAME'	=>	'FILENAMES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1028 => {
		'TAGNAME'	=>	'FILESIZES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1029 => {
		'TAGNAME'	=>	'FILESTATES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1030 => {
		'TAGNAME'	=>	'FILEMODES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1131 =>	{
	 	'TAGNAME'	=>	'RHNPLATFORM',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'RHN Platform',
		'TYPE'		=>	1
	},
	1132 =>	{
	 	'TAGNAME'	=>	'PLATFORM',
		'GROUP'		=>	'INFORMATION',
		'NAME'		=>	'RHN Platform',
		'TYPE'		=>	1
	},
	1033 => {
		'TAGNAME'	=>	'FILERDEVS',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1034 => {
		'TAGNAME'	=>	'FILEMTIMES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1035 => {
		'TAGNAME'	=>	'FILEMD5S',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1036 => {
		'TAGNAME'	=>	'FILELINKTOS',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1037 => {
		'TAGNAME'	=>	'FILEFLAGS',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1038 => {
		'TAGNAME'	=>	'ROOT',
		'GROUP'		=>	'OBSOLETED',
		'NAME'		=>	''
	},
	1039 => {
		'TAGNAME'	=>	'FILEUSERNAME',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1040 => {
		'TAGNAME'	=>	'FILEGROUPNAME',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1043 => {
		'TAGNAME'	=>	'ICON',
		'GROUP'		=>	'BINARY',
		'NAME'		=>	''
	},
	1044 => {
		'TAGNAME'	=>	'SOURCERPM',
		'GROUP'		=>	'USELESS',
		'NAME'		=>	''
	},
	1045 => {
		'TAGNAME'	=>	'FILEVERIFYFLAGS',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1046 => {
		'TAGNAME'	=>	'ARCHIVESIZE',
		'GROUP'		=>	'USELESS',
		'NAME'		=>	'Archive size including SIG'
	},
	1047 => {
		'TAGNAME'	=>	'PROVIDENAME',
		'GROUP'		=>	'PROVIDE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1048 => {
		'TAGNAME'	=>	'REQUIREFLAGS',
		'GROUP'		=>	'REQUIRE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1049 => {
		'TAGNAME'	=>	'REQUIRENAME',
		'GROUP'		=>	'REQUIRE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1050 => {
		'TAGNAME'	=>	'REQUIREVERSION',
		'GROUP'		=>	'REQUIRE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1053 => {
		'TAGNAME'	=>	'CONFLICTFLAGS',
		'GROUP'		=>	'CONFLICT',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1054 => {
		'TAGNAME'	=>	'CONFLICTNAME',
		'GROUP'		=>	'CONFLICT',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1055 => {
		'TAGNAME'	=>	'CONFLICTVERSION',
		'GROUP'		=>	'CONFLICT',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1057 => {
		'TAGNAME'	=>	'BUILDROOT',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1059 => {
		'TAGNAME'	=>	'EXCLUDEARCH',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1060 => {
		'TAGNAME'	=>	'EXCLUDEOS',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1061 => {
		'TAGNAME'	=>	'EXCLUSIVEARCH',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1062 => {
		'TAGNAME'	=>	'EXCLUSIVEOS',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1064 => {
		'TAGNAME'	=>	'RPMVERSION',
		'GROUP'		=>	'PAYLOAD',
		'NAME'		=>	''
	},
	1065 => {
		'TAGNAME'	=>	'TRIGGERSCRIPTS',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1066 => {
		'TAGNAME'	=>	'TRIGGERNAME',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1067 => {
		'TAGNAME'	=>	'TRIGGERVERSION',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1068 => {
		'TAGNAME'	=>	'TRIGGERFLAGS',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1069 => {
		'TAGNAME'	=>	'TRIGGERINDEX',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1079 => {
		'TAGNAME'	=>	'VERIFYSCRIPT',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1080 => {
		'TAGNAME'	=>	'CHANGELOGTIME',
		'GROUP'		=>	'CHANGELOG',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1081 => {
		'TAGNAME'	=>	'CHANGELOGNAME',
		'GROUP'		=>	'CHANGELOG',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1082 => {
		'TAGNAME'	=>	'CHANGELOGTEXT',
		'GROUP'		=>	'CHANGELOG',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1085 => {
		'TAGNAME'	=>	'PREINPROG',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1086 => {
		'TAGNAME'	=>	'POSTINPROG',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1087 => {
		'TAGNAME'	=>	'PREUNPROG',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1088 => {
		'TAGNAME'	=>	'POSTUNPROG',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1089 => {
		'TAGNAME'	=>	'BUILDARCHS',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1090 => {
		'TAGNAME'	=>	'OBSOLETENAME',
		'GROUP'		=>	'OBSOLETE',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1091 => {
		'TAGNAME'	=>	'VERIFYSCRIPTPROG',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1092 => {
		'TAGNAME'	=>	'TRIGGERSCRIPTPROG',
		'GROUP'		=>	'TRIGGER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1094 => {
		'TAGNAME'	=>	'COOKIE',
		'GROUP'		=>	'USELESS',
		'NAME'		=>	''
	},
	1095 => {
		'TAGNAME'	=>	'FILEDEVICES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1096 => {
		'TAGNAME'	=>	'FILEINODES',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1097 => {
		'TAGNAME'	=>	'FILELANGS',
		'GROUP'		=>	'FILE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1098 => {
		'TAGNAME'	=>	'PREFIXES',
		'GROUP'		=>	'PACKAGE',
		'NAME'		=>	'Prefixes',
		'TYPE'		=>	1
	},
	1099 => {
		'TAGNAME'	=>	'INSTPREFIXES',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1105 => {
		'TAGNAME'	=>	'RPMTAG_CAPABILITY',
		'GROUP'		=>	'OBSOLETED',
		'NAME'		=>	''
	},
	1107 => {
		'TAGNAME'	=>	'OLDORIGFILENAMES',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1111 => {
		'TAGNAME'	=>	'BUILDMACROS',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1112 => {
		'TAGNAME'	=>	'PROVIDEFLAGS',
		'GROUP'		=>	'PROVIDE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1113 => {
		'TAGNAME'	=>	'PROVIDEVERSION',
		'GROUP'		=>	'PROVIDE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1114 => {
		'TAGNAME'	=>	'OBSOLETEFLAGS',
		'GROUP'		=>	'OBSOLETE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1115 => {
		'TAGNAME'	=>	'OBSOLETEVERSION',
		'GROUP'		=>	'OBSOLETE',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1116 => {
		'TAGNAME'	=>	'DIRINDEXES',
		'GROUP'		=>	'FILERPM4',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1117 => {
		'TAGNAME'	=>	'BASENAMES',
		'GROUP'		=>	'FILERPM4',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1118 => {
		'TAGNAME'	=>	'DIRNAMES',
		'GROUP'		=>	'FILERPM4',
		'NAME'		=>	'',
		'TYPE'		=>	1

	},
	1122 => {
		'TAGNAME'	=>	'OPTFLAGS',
		'GROUP'		=>	'PACKAGE',
		'NAME'		=>	'BuildFlags',
		'TYPE'		=>	1
	},
	1123 => {
		'TAGNAME'	=>	'DISTURL',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1124 => {
		'TAGNAME'	=>	'PAYLOADFORMAT',
		'GROUP'		=>	'PAYLOAD',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1125 => {
		'TAGNAME'	=>	'PAYLOADCOMPRESSOR',
		'GROUP'		=>	'PAYLOAD',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1126 => {
		'TAGNAME'	=>	'PAYLOADFLAGS',
		'GROUP'		=>	'PAYLOAD',
		'NAME'		=>	'',
		'TYPE'		=>	1
	},
	1127 => {
		'TAGNAME'	=>	'MULTILIBS',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1128 => {
		'TAGNAME'	=>	'INSTALLTID',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1129 => {
		'TAGNAME'	=>	'REMOVETID',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	''
	},
	1177 => {
		'TAGNAME'	=>	'Filedigestalgos',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	4,
	},
	1140 => {
		'TAGNAME'	=>	'Sourcepkgid',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	4,
	},
	1141 => {
		'TAGNAME'	=>	'Fileclass',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	4,
	},
	1142 => {
		'TAGNAME'	=>	'Classdict',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	8,
	},
	1143 => {
		'TAGNAME'	=>	'Filedependsx',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	4,
	},
	1144 => {
		'TAGNAME'	=>	'Filedependsn',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	4,
	},
	1145 => {
		'TAGNAME'	=>	'Dependsdict',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	4,
	},
    1146 => {
		'TAGNAME'	=>	'Sourcepkgid',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
		'TYPE'		=>	7,
	},

	# fake tagnumber*10
	10000 => {
		'TAGNAME'	=>	'SIGSIZE',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'Signature Size',
		'TYPE'		=>	1
	},
		
	10010 => {
		'TAGNAME'	=>	'SIGMD5',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'MD5 Signature',
		'TYPE'		=>	1
	},
		
	10030 => {
		'TAGNAME'	=>	'SIGGPG',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'PGP Signature',
		'TYPE'		=>	1
	},
		
	10040 => {
		'TAGNAME'	=>	'SIGMD5',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'MD5 sum',
		'TYPE'		=>	1
	},
		
	10050 => {
		'TAGNAME'	=>	'SIGGPG',
		'GROUP'		=>	'SIGNATURE',
		'NAME'		=>	'PGP Signature',
		'TYPE'		=>	1,
	},

	10070 => {
		'TAGNAME'	=>	'UNKNOWN4',
		'GROUP'		=>	'OTHER',
		'NAME'		=>	'',
	}
);


EOF_RPM_HEADER_PUREPERL_TAGSTABLE_PM

export PERL5LIB=$tempdir/lib/perl5/site_perl

cat << \EOF_RPM_HEADER_PL > $tempdir/bin/rpmHeader.pl
#!/usr/bin/env perl
die "Missing package name." if ($#ARGV == -1);
my $fp = $ARGV[0];

use RPM::Header::PurePerl;

tie %HDR, "RPM::Header::PurePerl", $fp or die "An error occurred: $RPM::err";

if ($#ARGV == 1)
{
  $l = $HDR{$ARGV[1]};
  print join("\n", @$l);
  print "\n";
  exit;
}

while ( ($k,$v) = each %HDR) {
  $l = $HDR{$k};
  if ($ARGV == 0)
  {
    print "$k:";
    print join(",", @$l);
    print "\n";
  }
}
EOF_RPM_HEADER_PL

chmod u+x $rpmFindProvides $tempdir/bin/rpmHeader.pl

server=cmsrep.cern.ch
server_main_dir=cmssw
repository=cms
unsupportedDistribution=false
useDev=

rootdir=$(pwd)
xSeeds=""
xProvides=""
xSeedsRemove=""
keep_on_going=false
cmspkg_script_path=""
driver_file=""
seed_type="runtime"
while [ $# -gt 0 ]; do
  case $1 in
        setup )
          command=setup 
          shift ;;
        reseed )
          command=reseed
          shift;;
        -k) keep_on_going=true ; shift ;;
        -path|-p )
          [ $# -gt 0 ] || cleanup_and_exit 1 "Option \`$1' requires an argument"
          if [ "$(echo $2 | cut -b 1)" = "/" ]; then
            rootdir="$2"
          else
            rootdir="$PWD/$2"
          fi
          shift; shift ;;
        -server )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires an argument"
          server=$(echo $2 | cut -d/ -f1)
          server_path=$(echo $2/${server_main_dir} | cut -d/ -f2-100)
          [ "X$server_path" = "X" ] || server_main_dir=${server_path}
          shift; shift ;;
        -server-path )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires an argument"
          $hasRepository || cleanup_and_exit 1 "Cannot specify -repository and -server-path at the same time"
          server_main_dir=$(dirname $2)
          repository=$(basename $2)
          echo "server_main_dir $server_main_dir"
          echo "repository $repository"
          hasServerPath=true
          shift; shift ;;
        -repository|-r )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires an argument"
          $hasServerPath || cleanup_and_exit 1 "Cannot specify -repository and -server-path at the same time"
          repository=$2 
          hasRepository=true
          shift; shift ;;
        -architecture|-arch|-a )
            [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
            cmsplatf="$2"
            shift; shift ;;
        -driver)
            [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
            [ -e "$2" ]  || cleanup_and_exit 1 "No such file: $2"
            driver_file=$(realpath $2)
            shift; shift ;;
        -seed-type)
            [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
            case $2 in
              runtime|build) seed_type="$2" ;;
              *)  cleanup_and_exit 1 "Invalid value \`$2' for option \`$1'. Valid values are runtime|build. Default is runtime."
            esac
            shift; shift ;;
        -unsupported_distribution_hack )
          unsupportedDistribution=true; shift
          ;;
        -verbose|-v )
          verbose=true; shift
          doReturn="\n"
          ;;
        -debug )
          debug=true; shift
          doReturn="\n"
          ;;
        -dev )
          useDev="-dev"; shift
          ;;
        -assume-yes|-y )
          assumeYes=true; shift
          ;;
        -only-once )
          onlyOnce=true; shift
          ;;
        -additional-seed )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
          xSeeds="${xSeeds} $(echo $2 | tr ',' ' ')"
          shift; shift ;;
        -remove-seed )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
          xSeedsRemove="${xSeedsRemove} $(echo $2 | tr ',' ' ')"
          shift; shift ;;
        -additional-provides )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
          xProvides="${xProvides} $(echo \"$2\" | tr ',' ' ')"
          shift; shift ;;
        -additional-pkgs )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
          additionalPkgs="$additionalPkgs $(echo $2 | tr ',' ' ')"
          shift; shift ;;
        -cmspkg )
          [ $# -gt 1 ] || cleanup_and_exit 1 "Option \`$1' requires at lease one argument"
          [ -e "$2" ]  || cleanup_and_exit 1 "No such file: $2"
          cmspkg_script_path=$(realpath $2)
          shift; shift ;;
        -help|-h )
          cat << \EOF_HELP 
bootstrap.sh 

A script to bootstrap a CMS software area.

Syntax:
bootstrap.sh setup|reseed <-a|-arch|-architecture arch> [optional options]

setup|reseed                  Setup a new installation area or reconfigure/reseed and existing area.
-a|-arch|-architecture <arch> Select an architecture e.g slc7_amd64_gcc11

Optional options
-p|-path <cms-path>            Location of where the installation must be done (default: $PWD).
-r|-repository <repository>    Use private cmspkg repository cms.<username> (default: cms).
-server-path <download-path>   Package structure is found on <download-path> on server (default: cmssw).
-server <server>               Repositories are to be found on server <server> (default: cmsrep.cern.ch).
-seed-type runtime|build       Seed local installation area for runtime or runtime+build packages (default: runtime)
-additional-seed <csv>         Additional <csv> packages to seed for this install area.
-remove-seed     <csv>         Remove <csv> packages from default seeding.
-additional-provides <csv>     Search and seed packages which provides <cvs>.
-additional-pkgs <csv>         Additional packages to be installed.
-driver <local-driver>         Use a local directory file instead of downloading it from server.
-cmspkg <cmspkg-script>        Local cmspk script to be used instead of downloading from server.
-unsupported_distribution_hack Seed for unsupported distributions
-v|verbose                     Run in verbose mode
-debug                         Run in debug mode
-dev                           Use development cmspkg
-y|-assume-yes                 Assume yes as answer
-only-once                     Do not bootstrap installation area if already setup
-k                             Keep going without failure.
-h|-help                       Show this help message.
EOF_HELP
        cleanup_and_exit 1
        ;;
        * )
            cleanup_and_exit 1 "bootstrap.sh: argument $1 not supported"
        ;;
    esac
done

# Get cmsos from the web.
cgi_server=
found_server=no
for x in $(echo ${server}/${server_main_dir} | tr / ' ') ; do
  [ "X$cgi_server" = "X" ] && cgi_server=$x || cgi_server=$cgi_server/$x
  rm -f $tempdir/ping
  download_${download_method} "$cgi_server/cgi-bin/cmspkg${useDev}?ping=1" $tempdir/ping || true
  if [ -f $tempdir/ping ] ; then
    if [ "X$(cat $tempdir/ping)" = "XCMSPKG OK" ] ; then
      found_server=yes
      break
    fi
  fi
done
[ "$found_server" = "yes" ] || cleanup_and_exit 1 "Unable to find /cgi-bin/cmspkg on $server"

# Use cmsos to guess the platform if it is not set on command line.
if [ "X$cmsplatf" = X ] ; then
  cmsos="$(echo $server | cut -d/ -f1)/${server_main_dir}/repos/cmsos"
  [ "X$verbose" = Xtrue ] && echo_n "Downloading cmsos file..."
  download_${download_method} "$cmsos" $tempdir/cmsos
  [ -f $tempdir/cmsos ] || cleanup_and_exit 1 "FATAL: Unable to download cmsos: $cmsos"
  source $tempdir/cmsos
  cmsarch=`cmsos`
  cmsplatf=${cmsarch}_`defaultCompiler`
else
  cmsarch=$(echo $cmsplatf | cut -d_ -f1,2)
fi

case $cmsplatf in
  osx*)
    cpio_opts="--insecure";;
esac

rpmdb=$cmsplatf/var/lib/rpm
rpmlock=$rootdir/$cmsplatf/var/lib/rpm/__db.0
importTmp=$rootdir/$cmsplatf/tmp/system-import

[ "X$verbose" = Xtrue ] && echo "Using $download_method to download files."
[ "X$verbose" = Xtrue ] && echo "RPM db in $cmsplatf/var/lib/rpm."

perlHarvester () {
    [ "X$verbose" = Xtrue ] && echo && echo "...Harvesting for perl modules" 1>&2
    for x in $(perl -e 'print "@INC\n"'); do
        find -L $x 2>/dev/null |
            grep -v -e '\(^[.]/\|[/]$\)' |
            grep -e '\([.]p[lm]$\|[.]pod$\)' |
            sed -e "s|$x/||;s|^[0-9.]*/||;s|^[-a-z0-9]*-thread-multi/||;s|[.]p[ml]||;s|[.]pod||;s|/|::|g;s|^\(.*\)|Provides: perl(\1)|"
    done | sort | uniq
}

provide2package () {
  rpm -q --whatprovides --queryformat '%{NAME}\n' "$1"
}

checkPackage_DPKG () {
    [ "$(dpkg -L $1 2>&1 | grep 'is not installed')" = "" ] && return 0
    return 0
}

checkPackage_RPM () {
    rpm -q $1 >/dev/null 2>&1
}

checkPackage () {
    for p in $(echo $1 | tr '|' ' '); do
        if checkPackage_$2 $p >/dev/null 2>&1 ; then echo $p ; return 0; fi
    done
}

get_platformSeeds () {
  requiredSeeds=$(eval echo $`get_cmsos`_$1)
  if [ "X$requiredSeeds" = X ] ; then
    requiredSeeds=$(eval echo $`get_cmsos | sed -e 's|\([0-9]\)[0-9]*|\1|'`_$1)
  fi
}

generateSeedSpec () {
    # Seed system info
    # GL asound odbc java libtcl libtk
    [ "X$verbose" = Xtrue ] && echo && echo "...Seeding RPM database from selected system RPMs." 1>&2
    
    # Decide which seeds to use. Notice that in case
    # rhXYZ_WWW_ does not exists we try to use
    # rhX_WWW_ platformSeeds before dropping to
    # the (optional) platformSeeds. 
    get_platformSeeds platformSeeds
    if [ "X$requiredSeeds" = X ]; then
      seed="$platformSeeds"
    else
      seed="$requiredSeeds"
      unsupportedDistribution=false
    fi
    ERR=false
    requiredBuildSeeds=""
    if [ "${seed_type}" = "build" ] ; then
      get_platformSeeds platformBuildSeeds
      requiredBuildSeeds="${requiredSeeds}"
      for p in $(eval echo $`get_cmsos`_packagesWithBuildProvides); do
        s=$(provide2package "$p") || true
        if [ "X$s" = "X" ] || [ $(echo "$s" | grep 'no package provides' | wc -l) -gt 0 ]; then
          echo "ERROR: Unable to find package to provide '$p'. Software might fail at build time."
          if $keep_on_going ; then continue ; fi
          ERR=true
        fi
      done
    fi
    for p in $(eval echo $`get_cmsos`_packagesWithProvides) ${xProvides}; do
      s=$(provide2package "$p") || true
      if [ "X$s" = "X" ] || [ $(echo "$s" | grep 'no package provides' | wc -l) -gt 0 ]; then
        additionalProvides="$p ${additionalProvides}"
        echo "ERROR: Unable to find package to provide '$p'. Software might fail at runtime."
        if $keep_on_going ; then continue ; fi
        ERR=true
      else
        for x in $s ; do xSeeds="${xSeeds} ${x}" ; done
      fi
    done
    if $ERR ; then
      echo "Use '-k' option to ignore this error and keep on going"
      exit 1
    fi
    seed="$(echo "${seed} ${xSeeds}" | tr ' ' '\n' | grep -v '^$' | sort | uniq | tr '\n' ' ')"
    if [ "${xSeedsRemove}" ] ; then
      xSeedsRemove="^\\($(echo $xSeedsRemove | sed 's/  */\\|/g')\)\$"
      seed=$(echo "$seed" | tr ' ' '\n' | grep -v "${xSeedsRemove}" | tr '\n' ' ')
    fi

    if $unsupportedDistribution
    then
        echo "WARNING: you are running on an unsupported distribution."
        echo "This might lead to unknown problems."
        seed="$seed $unsupportedSeeds"
    fi

     rm -rf $importTmp
     mkdir -p $importTmp
     cd $importTmp
     mkdir -p SOURCES BUILD SPEC RPMS SRPMS tmp
     : > SOURCES/none
     # FIXME: It might be better to use rootdir rather than PWD
     (echo "%define _sourcedir      $PWD/SOURCES"
      echo "%define _builddir       $PWD/BUILD"
      echo "%define _specdir        $PWD/SPEC"
      echo "%define _rpmdir         $PWD/RPMS"
      echo "%define _srcrpmdir      $PWD/SRPMS"
      echo "%define _tmppath        $PWD/tmp"
      echo "%define _topdir         $PWD"
      echo "%define _rpmfilename    system-base-import.rpm"
      echo;
      echo "Name: system-base-import"
      echo "Version: 1.0"
      echo "Release: `date +%s`"
      echo "Summary: Base system seed"
      echo "License: Unknown"
      echo "Group: Hacks"
      echo "Packager: install.sh"
      echo "Source: none"
      for provide in $additionalProvides
      do
        echo "Provides: $provide"
      done
      
      if $unsupportedDistribution
      then
        # Guess perl
		echo "Provides: perl = `perl -MConfig -e 'print $Config{api_revision}.\".\".($Config{api_version}*1000).$Config{api_subversion};'`"
        for provide in $unsupportedProvides
        do
            echo "Provides: $provide"
        done
      fi
      
      case $cmsplatf in
        osx* )
	    ls /System/Library/Frameworks | grep -v -e '[ ()]' | sed 's!.framework!!;s!^!Provides: !'
  	    find /usr/bin | grep -v -e '[ ()]' | sed 's!^!Provides: !'
  	    find /bin | grep -v -e '[ ()]' | sed 's!^!Provides: !'
    	    /bin/ls -1 /usr/lib/*.dylib | grep -v -e '[ ()]' | awk -F"/" '{print $4}' | sed 's!^!Provides: !' || true
    	    /bin/ls -1 /usr/lib/*/*.dylib | grep -v -e '[ ()]' | awk -F"/" '{print $5}' | sed 's!^!Provides: !' || true
            /bin/ls -1 /usr/X11R6/lib/*.dylib | grep -v -e '[ ()]' | awk -F"/" '{print $5}' | sed 's!^!Provides: !' || true
        ;;
      esac

      pkgManager=""
      if command -v rpm >/dev/null 2>&1 ; then
          [ "X$verbose" = Xtrue ] && echo && echo "...rpm found in $(command -v rpm), using it to seed the database." >&2
          pkgManager="RPM"
      elif command -v dpkg >/dev/null 2>&1 ; then
          [ "X$verbose" = Xtrue ] && echo && echo "...dpkg found in $(command -v dpkg), using it to seed the database." >&2
          pkgManager="DPKG"
      else
          echo 1>&2
          echo "DPKG or RPM not found." 1>&2
          exit 1
      fi
      missingSeeds=""
      selSeeds=""
      for pp in $seed; do
          p=$(checkPackage "$pp" ${pkgManager})
          if [ "$p" = "" ] ; then
              missingSeeds="$missingSeeds $pp"
          else
              selSeeds="${selSeeds} ${p}"
          fi
      done
      for pp in ${requiredBuildSeeds}; do
          p=$(checkPackage "$pp" ${pkgManager})
          if [ "$p" = "" ] ; then
              missingSeeds="$missingSeeds $pp"
          fi
      done
      if [ "$missingSeeds" ] ; then
          echo 1>&2
          echo "Some required packages are missing:" 1>&2
          echo $missingSeeds 1>&2
          exit 1
      fi
      for p in $(echo ${selSeeds} |  sort | uniq) ; do
          if [ "$pkgManager" = "DPKG" ] ; then
              dpkg -L $p 2>/dev/null | sed -e "s|^|Provides:|"
              dpkg -L $p 2>/dev/null | $rpmFindProvides | sed -e "s|^|Provides:|" || true
          elif [ "$pkgManager" = "RPM" ] ; then
              rpm -q $p --provides | sed 's!<*=.*!!; s!^!Provides: !' || true
              rpm -q $p --list | grep -F .so | grep -F -v -e /lib/. -e /lib64/. | sed 's!^.*/!Provides: !' || true
              rpm -q $p --list | grep -F /bin/ | sed 's!^!Provides: !' || true
          fi
      done
      [ "$pkgManager" = "DPKG" ] && perlHarvester
      echo; echo "%description"; echo "Seeds RPM repository from the base system."
      echo; echo "%prep"; echo "%build"; echo "%install"; echo "%files";
     ) > system-base-import.spec
    if [ "X$?" = X0 ]; then : ; else 
        echo "There was an error generating the platform seed"
        exit 1
    fi

    perl -p -i -e 's|^Provides:[\s]*$||' system-base-import.spec
    cd $was
}

seed ()
{
    rcfile=$1
    pushd $importTmp
    init_file=$rootdir/bootstraptmp/BOOTSTRAP/inst/$cmsplatf/external/rpm/$rpm_version/etc/profile.d/init.sh
    if [ "$command" = "reseed" ] ; then
      init_file=$rootdir/$cmsplatf/external/rpm/$rpm_version/etc/profile.d/init.sh
    fi
    (source $init_file
     rm -rf $tempdir/BUILDROOT && mkdir -p $tempdir/BUILDROOT
     rpmbuild -ba --define "_topdir $PWD" --rcfile $rcfile --buildroot $tempdir/BUILDROOT system-base-import.spec >/dev/null 2>&1
     [ "X$verbose" = Xtrue ] && echo && echo "...Seeding database in in $rootdir/$rpmdb"
     rpm --define "_rpmlock_path $rpmlock" -U --ignoresize ${rpmBaseOptions} --rcfile $rcfile RPMS/system-base-import.rpm
    ) || cleanup_and_exit $? "Error while seeding rpm database with system packages."
    popd
}

get_driver() {
# Get the architecture driver from the web
if [ "$driver_file" = "" ] ; then
  driver="$cgi_server/cgi-bin/cmspkg${useDev}/driver/$repository/$cmsplatf?repo_uri=${server_main_dir}"
  echo_n "Downloading driver file $cmsplatf..."
  download_${download_method} "$driver" $tempdir/$cmsplatf-driver.txt
  [ -f $tempdir/$cmsplatf-driver.txt ] || cleanup_and_exit 1 "Unable to download platform driver: $driver"
  eval `cat $tempdir/$cmsplatf-driver.txt`
  echo "Done driver $cmsplatf."
  #Setting up optional drivers
  for arch in $(echo $cmsplatf | sed 's|_[^_]*$||')_common common_$(echo $cmsplatf | sed 's|^[^_]*_||;s|_[^_]*$||')_common ; do
    driver="$cgi_server/cgi-bin/cmspkg${useDev}/driver/$repository/$arch?repo_uri=${server_main_dir}"
    echo_n "Downloading driver file $arch ..."
    download_${download_method} "$driver" $tempdir/$arch-driver.txt || continue
    [ -f $tempdir/$arch-driver.txt ]
    eval `cat $tempdir/$arch-driver.txt`
    echo "Done driver $arch."
  done
else
  eval `cat $driver_file`
fi
}

setup() {
# FIXME: this is the ugliest trick ever found in a shell script.
# The problem is that rpm sometimes applies the value of --root
# to dbpath, some other times it does not.
# At some point this should be really fixed in the rpm sources,
# but for the time being we keep it as it is.
[ "$rootdir" = "" ] && cleanup_and_exit 1 "Installation path not specified."

rootdir=`echo $rootdir | perl -p -e 's|/$||'`
mkdir -p $rootdir
eval `echo $rootdir | awk -F \/ '{print "fakelink=$rootdir/"$2}'`
if [ ! -e $fakelink ]
then
    #echo $rootdir | awk -F \/ '{print "ln -s /"$2" $rootdir/"$2}'
    command=`echo $rootdir | awk -F \/ '{print "ln -s /"$2" $rootdir/"$2}'`
    eval $command
fi

# Fetch the required RPMS for RPM and APT from the server and install them using rpmcpio
export DOWNLOAD_DIR=$rootdir/bootstraptmp/BOOTSTRAP
mkdir -p $DOWNLOAD_DIR
cd $DOWNLOAD_DIR
get_driver

cmspkg_opts=""
cmspkg_debug=""
[ "X$debug" = "Xtrue" ] && cmspkg_debug="--debug"
[ -z $useDev ]          || cmspkg_opts="${cmspkg_opts} --use-dev"
CMSPKG_SCRIPT="cmspkg.py ${cmspkg_debug} ${cmspkg_opts} --server $cgi_server --server-path $server_main_dir --repository $repository --architecture $cmsplatf"
if [ "$cmspkg_script_path" ] ; then
  cp ${cmspkg_script_path} $tempdir/cmspkg.py
else
  cmspkg=$(echo $server | cut -d/ -f1)/${server_main_dir}/repos/cmspkg${useDev}.py
  download_${download_method} $cmspkg $tempdir/cmspkg.py
fi
[ -f $tempdir/cmspkg.py ] || cleanup_and_exit 1 "FATAL: Unable to download cmspkg: $cmspkg"
chmod +x $tempdir/cmspkg.py
echo "Downloading bootstrap core packages..."
$tempdir/$CMSPKG_SCRIPT --path $DOWNLOAD_DIR download $packageList || cleanup_and_exit 1 "Error downloading $pkg. Exiting."
for pkg in $packageList
do
    mv $DOWNLOAD_DIR/$cmsplatf/var/cmspkg/rpms/$pkg $pkg
done
echo "Done."

was=`pwd`
cd $rootdir
forceOption=""
if [ -d $rootdir/$rpmdb ]
then
    [ "X$onlyOnce" = Xtrue ] && cleanup_and_exit 0 "Area already initialised. Skipping bootstrap and exiting."
    if [ "X$assumeYes" = Xtrue ]
    then
        forceOption=--force
    else
        read -e -p "Warning, $rootdir already set up. Do you want to reconfigure it? [ y / N ] " override
        case $(echo $override | tr [A-Z] [a-z]) in
            y|ye|yes) 
                forceOption=--force
                ;;
            *) 
                cleanup_and_exit 0 "No changes made. Exiting... " 
            ;;
        esac
    fi
else
    mkdir -p $rootdir/$rpmdb
fi

# Extract the packages via rpm, source the init.sh
# Some packages might actually not be there (gcc on darwin, for example, .
# where we use the system one).
cd $DOWNLOAD_DIR
# http://linuxmafia.com/pub/linux/utilities-general/rpm2cpio
cat > myrpm2cpio <<\EOF_RPM2CPIO
#!/usr/bin/env perl

# Why does the world need another rpm2cpio?  Because the existing one
# won't build unless you have half a ton of things that aren't really
# required for it, since it uses the same library used to extract RPMs.
# In particular, it won't build on the HPsUX box I'm on.

#
# Expanded quick-reference help by Rick Moen (not the original author
# of this script).
#

# add a path if desired
$gzip = "gzip";

sub printhelp {
  print "\n";
  print "rpm2cpio, perl version by orabidoo <odar\@pobox.com>\n";
  print "\n";
  print "use: rpm2cpio [file.rpm]\n";
  print "\n";
  exit 0;
}

if ($#ARGV == -1) {
  printhelp if -t STDIN;
  $f = "STDIN";
} elsif ($#ARGV == 0) {
  open(F, "< $ARGV[0]") or die "Can't read file $ARGV[0]\n";
  $f = 'F';
} else {
  printhelp;
}

printhelp if -t STDOUT;

# gobble the file up
undef $/;
$|=1;
$rpm = <$f>;
close ($f);

($magic, $major, $minor, $crap) = unpack("NCC C90", $rpm);

die "Not an RPM\n" if $magic != 0xedabeedb;
die "Not a version 3 or 4 RPM\n" if $major != 3 and $major != 4;

$rpm = substr($rpm, 96);

while ($rpm ne '') {
  $rpm =~ s/^\c@*//s;
  ($magic, $crap, $sections, $bytes) = unpack("N4", $rpm);
  $smagic = unpack("n", $rpm);
  last if $smagic eq 0x1f8b;
  die "Error: header not recognized\n" if $magic != 0x8eade801;
  $rpm = substr($rpm, 16*(1+$sections) + $bytes);
}

die "bogus RPM\n" if $rpm eq '';

open(ZCAT, "|gzip -cd") || die "can't pipe to gzip\n";

print ZCAT $rpm;
close ZCAT;
EOF_RPM2CPIO

echo_n "Unpacking core packages..."
# Unfortunately cpio unpacks its files including the original build path.
# We therefore need some symlink tricks to make sure that everything
# ends up in the same installation directory. 
# We also use the rpmHeader.pl script to get the pre and post install
# script and we execute them by hand.
# This should really mimic what rpm does and removes the needs for
# `instroot` to be defined in the bootstrap driver.
mkdir $tempdir/scriptlets
mkdir -p $PWD/inst
for pkg in $packageList
do
    tmpInstDir=$tempdir/unpack_$pkg
    pkgInstRoot=`$tempdir/bin/rpmHeader.pl $DOWNLOAD_DIR/$pkg PREFIXES | tail -1`
    pkgFinalInstDir=$PWD/inst
    (mkdir -p $tmpInstDir;                                                            \
     cd $tmpInstDir                                                                   \
       && perl $DOWNLOAD_DIR/myrpm2cpio $DOWNLOAD_DIR/$pkg | cpio $cpio_opts -id      \
       && cp -ar ${tmpInstDir}${pkgInstRoot}/* $pkgFinalInstDir/                     \
       || cleanup_and_exit 1 "Unable to unpack $DOWNLOAD_DIR/$pkg";                   \
     rm -rf $tmpInstDir)
    $tempdir/bin/rpmHeader.pl $DOWNLOAD_DIR/$pkg PREIN | grep -v "^Unknown" | sed -e "s|[$]RPM_INSTALL_PREFIX|$PWD/inst|g" > $tempdir/scriptlets/$pkg.pre.sh
    sh -e $tempdir/scriptlets/$pkg.pre.sh
    perl ./myrpm2cpio $DOWNLOAD_DIR/$pkg | cpio $cpio_opts -id || cleanup_and_exit 1 "Unable to unpack $DOWNLOAD_DIR/$pkg"
    $tempdir/bin/rpmHeader.pl $DOWNLOAD_DIR/$pkg POSTIN | grep -v "^Unknown" | sed -e "s|[$]RPM_INSTALL_PREFIX|$PWD/inst|g" > $tempdir/scriptlets/$pkg.post.sh
    sh -e $tempdir/scriptlets/$pkg.post.sh
done
echo "Done."

# Generate the seed spec using the old rpm:
echo_n "Harvesting system for locally available software..."
generateSeedSpec

RPM_EXTRA_OPTS=""
RPM_VERSION_NUM=$(echo $rpm_version | sed -E -e 's|^([0-9]+)\.([0-9]+).*|\1.00\2|' | sed -E -e 's|\.0*([0-9]{3})$|\1|')
if [ $(echo ${RPM_VERSION_NUM} | grep -E '^[0-9]+$' | wc -l) -gt 0 ] ; then
  [ $RPM_VERSION_NUM -ge 4020 ] && RPM_EXTRA_OPTS="--noplugins"
fi
# Now move to use the new RPM by sourcing its init.sh
source $DOWNLOAD_DIR/inst/$cmsplatf/external/rpm/$rpm_version/etc/profile.d/init.sh
rpmBaseOptions="-r $rootdir --dbpath $rootdir/$rpmdb"
if [ "${CMSPKG_SYSTEM_RPM}" = "1" ] ; then
  rpmBaseOptions="--dbpath $rootdir/$rpmdb"
fi
cd $rootdir
echo "Done."

# Initialise the rpmdb using the new rpm.
echo_n "Initializing local rpm database..."
rpmdb --define "_rpmlock_path $rpmlock" ${rpmBaseOptions} --initdb || cleanup_and_exit 1 "Unable to initialize $rootdir/$rpmdb. Exiting."

# Build the seed spec and install it, in order to seed the newly generated db.
rpmOptions="${rpmBaseOptions} --rcfile $DOWNLOAD_DIR/inst/$cmsplatf/external/rpm/$rpm_version/lib/rpm/rpmrc --nodeps --prefix $rootdir --ignoreos --ignorearch"
seed $DOWNLOAD_DIR/inst/$cmsplatf/external/rpm/$rpm_version/lib/rpm/rpmrc
echo "Done."

# Install the packages, this time using rpm.
echo_n "Installing packages in the local rpm database..."
for pkg in $packageList
do
    rpm -U $forceOption ${RPM_EXTRA_OPTS} --ignoresize --define "_rpmlock_path $rpmlock" $rpmOptions $DOWNLOAD_DIR/$pkg || cleanup_and_exit 1 "Error while installing $pkg. Exiting."
done
echo "Done"

$tempdir/$CMSPKG_SCRIPT --path $rootdir setup
echo_n "Installing default packages."
defaultPackages="$additionalPkgs $defaultPkgs"
[ "X$defaultPackages" = X ] || $rootdir/common/cmspkg ${cmspkg_debug} --architecture $cmsplatf --ignore-size -f install $defaultPackages >$tempdir/apt-get-install.log 2>&1 || (cat $tempdir/apt-get-install.log  && cleanup_and_exit 1 "There was a problem while installing the default packages ")
[ "X$debug" = "Xtrue" ] && cat $tempdir/apt-get-install.log
echo "Done"

echo "Bootstrap environment to be found in: "
echo "### $rootdir/$cmsplatf/external/apt/$apt_version/etc/profile.d/init.sh"

cd $was
}

##########################################################
case $command in
    setup )
        setup 
        ;;
    reseed )
        get_driver
        generateSeedSpec
        seed $rootdir/$cmsplatf/external/rpm/$rpm_version/lib/rpm/rpmrc 
        ;;
esac

cleanup_and_exit 0 "Everything completed correctly."
