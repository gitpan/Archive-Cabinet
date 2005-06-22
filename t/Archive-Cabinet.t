# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Archive-Cabinet.t'

#########################

use Test::Harness;

use Test::More tests => 11;
BEGIN { use_ok('Archive::Cabinet') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

# new() tests
{
    my $cab = new Archive::Cabinet;
    isnt($cab, NULL, "new()");

    my $cab2 = new Archive::Cabinet 'badfile.CAB';
    is($cab2, undef, "new('bad_filename')");

    my $cab3 = new Archive::Cabinet 'testcab.cab';
    isnt($cab3, NULL, "new('valid_filename')");
    my $ret = $cab3->close();
}

# open() tests
{
    my $cab = new Archive::Cabinet;
    my $ret = $cab->open('testcab.cab');
    isnt($ret, undef, "open('valid_filename')");
    $ret = $cab->close();
}

# close() tests
{
    my $cab = new Archive::Cabinet 'testcab.cab';
    my $ret = $cab->close();
    is($ret, 0, "close('valid_filename')");
}

# extract_all() tests
{
    my $cab = new Archive::Cabinet 'testcab.cab';
    my $ret = $cab->extract_all();
    is($ret, 1, "extract_all()");
    $ret = $cab->close();

    # Remove extracted files
#    unlink 'dasetup.exe';
}

# extract_to_file() tests
{
    my $cab = new Archive::Cabinet 'testcab.cab';
    my $ret = $cab->extract_to_file('CFFILE.H', 'CFFILE1.H');
    is($ret, 1, "extract_to_file('valid_filename')");
    $ret = $cab->close();

    # Remove extracted file
    unlink 'CFFILE1.H';
}

# extract() tests
{
    my $buf;

    my $cab = new Archive::Cabinet 'testcab.cab';
    $buf = $cab->extract('CFFILE.H');

#    diag($buf);

    my $ret = $cab->close();
    isnt($buf, NULL, "extract('valid_file')");
}

# list_files() tests
{
    my $cab = new Archive::Cabinet 'testcab.cab';
    my $list = $cab->list_files();

#    diag($list->[0]);

    my $ret = $cab->close();
    is($list->[0], 'CFDATA.CPP', "list_files('valid_file')");
}

# get_file_attributes() tests
{
    my $cab = new Archive::Cabinet 'testcab.cab';
    my $cabhash = $cab->get_file_attributes();

#    diag(%$cabhash);

    my $ret = $cab->close();
    isnt(%$cabhash, NULL, "get_file_attributes('valid_file')");
}
