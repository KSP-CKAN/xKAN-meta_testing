#!/usr/bin/perl
use v5.010;
use lib 't/lib';
use autodie;
use strict;
use Test::Most;
use Test::NetKAN qw(netkan_files read_netkan licenses);
use Perl::Version;

use Data::Dumper;

my $ident_qr = qr{^[A-Za-z0-9-]+$};

my %licenses = licenses();

my %files = netkan_files;

foreach my $shortname (sort keys %files) {
    my $metadata = read_netkan($files{$shortname});

    is(
        $metadata->{identifier},
        $shortname,
        "$shortname.netkan identifier should match filename"
    );

    like(
        $metadata->{identifier},
        $ident_qr,
        "$shortname: CKAN identifiers must consist only of letters, numbers, and dashes, and must start with a letter or number."
    );

    my $spec_version = $metadata->{spec_version};

    foreach my $relation (qw(depends recommends suggests conflicts supports)) {
        foreach my $rel (@{$metadata->{$relation}}) {
            if ($rel->{any_of}) {
                ok(
                    compare_version($spec_version, "v1.26"),
                    "$shortname - spec_version v1.26+ required for 'any_of'"
                );
                foreach my $mod ($rel->{any_of}) {
                    like(
                        $mod->{name},
                        $ident_qr,
                        "$shortname: $mod->{name} in $relation any_of is not a valid CKAN identifier"
                    );
                }
            } else {
                like(
                    $rel->{name},
                    $ident_qr,
                    "$shortname: $rel->{name} in $relation is not a valid CKAN identifier"
                );
            }
        }
    }

    my $mod_license = $metadata->{license} // "(none)";
    my $kref = $metadata->{'$kref'} // "(none)";

    if ( $kref !~ /^\#\/ckan\/netkan/ ) {
        if (ref($mod_license) eq "ARRAY") {
            foreach my $lic (@{$mod_license}) {
                ok(
                    $metadata->{x_netkan_license_ok} || $licenses{$lic},
                    "$shortname license ($lic) should match spec. Set `x_netkan_license_ok` to supress."
                );
            }
        } else {
            ok(
                $metadata->{x_netkan_license_ok} || $licenses{$mod_license},
                "$shortname license ($mod_license) should match spec. Set `x_netkan_license_ok` to supress."
            );
        }
    }

    if ( defined $metadata->{'download'} ) {
      ok(
          ! defined $metadata->{'$kref'},
          "$shortname has a \$kref/\$vref and a download field, this is likely incorrect."
      );
      ok(
          defined $metadata->{'version'},
          "$shortname expects a version when a download url is provided."
      );
    } else {
      ok(
          $metadata->{'$kref'} || $metadata->{'$vref'},
          "$shortname has no \$kref/\$vref field, this is required when no download url is specified."
      );
    }

    if (my $overrides = $metadata->{x_netkan_override}) {

        my $is_array = ref($overrides) eq "ARRAY";

        ok($is_array, "Netkan overrides require an array");

        # If we don't have an array, then skip this next part.
        $overrides = [] if not $is_array;

        foreach my $override (@$overrides) {
            ok(
                $override->{version},
                "$shortname - Netkan overrides require a version"
            );

            ok(
                $override->{delete} || $override->{override},
                "$shortname - Netkan overrides require a delete or override section"
            );
        }
    }

    ok(
        $spec_version =~ m/^1$|^v\d\.\d\d?$/,
        "spec version must be 1 or in the 'vX.X' format"
    );

    if ($mod_license eq "WTFPL") {
        ok(
            compare_version($spec_version,"v1.2"),
            "$shortname - spec_version v1.2+ required for license 'WTFPL'"
        );
    }

    if ($mod_license eq "Unlicense") {
        ok(
            compare_version($spec_version,"v1.18"),
            "$shortname - spec_version v1.18+ required for license 'Unlicense'"
        );
    }

    if ($metadata->{ksp_version_strict}) {
        ok(
            compare_version($spec_version,"v1.16"),
            "$shortname - spec_version v1.16+ required for 'ksp_version_strict'"
        );
    }

    foreach my $install (@{$metadata->{install}}) {
        if ($install->{install_to} =~ m{^GameData/}) {
            ok(
                compare_version($spec_version,"v1.2"),
                "$shortname - spec_version v1.2+ required for GameData with path."
            );
        }

        if ($install->{install_to} =~ m{^Ships/}) {
            ok(
                compare_version($spec_version,"v1.12"),
                "$shortname - spec_version v1.12+ required to install to Ships/ with path."
            );
        }

        if ($install->{install_to} =~ m{^Ships/\@thumbs}) {
            ok(
                compare_version($spec_version,"v1.16"),
                "$shortname - spec_version v1.16+ required to install to Ships/\@thumbs with path."
            );
        }

        if ($install->{find}) {
            ok(
                compare_version($spec_version,"v1.4"),
                "$shortname - spec_version v1.4+ required for install with 'find'"
            );
        }

        if ($install->{find_regexp}) {
            ok(
                compare_version($spec_version,"v1.10"),
                "$shortname - spec_version v1.10+ required for install with 'find_regexp'"
            );
        }

        if ($install->{find_matches_files}) {
            ok(
                compare_version($spec_version,"v1.16"),
                "$shortname - spec_version v1.16+ required for 'find_matches_files'"
            );
        }

        if ($install->{as}) {
            ok(
                compare_version($spec_version,"v1.18"),
                "$shortname - spec_version v1.18+ required for 'as'"
            );
        }
    }

}

sub compare_version {
  my ($spec_version, $min_version) = @_;
  return Perl::Version->new($spec_version) >= Perl::Version->new($min_version);
}

done_testing;
