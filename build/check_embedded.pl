#!/usr/bin/perl -w
use POSIX qw(floor);
use File::Temp qw(tempfile);
use Date::Parse;
use Digest::SHA1 qw(sha1 sha1_hex sha1_base64);

#
# Perform checks on a series of certificates that are to be, or have been, embedded in the
# UK federation metadata.
#
# The certificates are provided on standard input in PEM format with header lines
# indicating the entity with which they are associated.
#
# Command line options:
#
#	-q	quiet		don't print anything out if there are no problems detected
#

#
# Number of days when we issue a warning
#
my $daysBeforeWarning = 43;

#
# Number of days when we issue an error
#
my $daysBeforeError = 18;

#
# Number of days in the past we should regard as "long expired".
#
my $longExpiredDays = 30*3; # about three months

#
# Request verbose tabulation of certificate issuers.
#
my $verboseIssuers = 0;

#
# Issuer marks (only shown in the absence of verboseIssuers)
#
my %issuerMark;

# From the UK federation trust roots document.
$issuerMark{'AddTrust External CA Root'} = 'R';
$issuerMark{'UTN-USERFirst-Hardware'} = 'i';
$issuerMark{'TERENA SSL CA'} = 'i';

# ex-roots
$issuerMark{'GlobalSign Root CA'} = 'X';
$issuerMark{'GlobalSign Organization Validation CA'} = 'x';
$issuerMark{'GlobalSign Primary Secure Server CA'} = 'x';
$issuerMark{'GlobalSign ServerSign CA'} = 'x';

#
# Load expiry whitelist.
#
open WL, '../build/expiry_whitelist.txt' || die "can't open certificate expiry whitelist";
while (<WL>) {
	# fold lines
	while (/^(.*)\\\s*$/) {
		chomp;
		$_ .= ' ' . <WL>;
	}
	next if /^\s*#/;	# drop comments
	next if /^\s*$/;	# drop blank lines
	my ($fingerprint) = split;
	$expiry_whitelist{uc $fingerprint} = 'unused';
}

sub error {
	my($s) = @_;
	push(@olines, '   *** ' . $s . ' ***');
	$printme = 1;
}

sub warning {
	my ($s) = @_;
	push(@olines, '   ' . $s);
	$printme = 1;
}

sub comment {
	my($s) = @_;
	push(@olines, '   (' . $s . ')');
}

#
# Process command-line options.
#
while (@ARGV) {
	$arg = shift @ARGV;
	$quiet = 1 if $arg eq '-q';
}

#
# Hash of already-seen blobs.
#
# Each entry in the hash is indexed by the blob itself.  Each blob is a concatenated
# sequence of information that uniquely identifies an already checked key.  This is
# used to avoid processing the same blob more than once.
#
my %blobs;

#
# Blob currently being constructed.
#
my $blob;

#
# Track most distant notAfter time.
#
my $lastNotAfterTime = 0;
my $lastNotAfter;
my $lastNotAfterEntity;

#
# Track maximum certificate expiry year
#
$maxYear = 0;

#
# Track number of certificates expiring during or after 2038,
# in which unsigned Unix time wraps negative.
#
$num2038 = 0;

my $total_certs = 0;

while (<>) {

	#
	# Discard blank lines.
	#
	next if /^\s*$/;
	
	#
	# Handle Entity/KeyName header line.
	#
	if (/^Entity:/) {
		@olines = ();
		$printme = 0;
		@args = split;
		$entity = $args[1];
		$keyname = $args[3];
		
		#
		# Output header line.
		#
		$oline = "Entity $entity ";
		$hasKeyName = !($keyname eq '(none)');
		if ($hasKeyName) {
			$oline .= "has KeyName $keyname";
		} else {
			$oline .= "has no KeyName";
		}
		push(@olines, $oline);

		#
		# Start building a new blob.
		#
		# The blob contains the entity name, so de-duplication
		# only occurs within a particular entity and not across
		# entities.
		#
		$blob = $oline;

		#
		# Create a temporary file for this certificate in PEM format.
		#
		($fh, $filename) = tempfile(UNLINK => 1);
		#print "temp file is: $filename\n";

		# do not buffer output to the temporary file
		select((select($fh), $|=1)[0]);
		next;
	}
	
	#
	# Put other lines into a temporary file.
	#
	print $fh $_;
	$blob .= '|' . $_;
	
	#
	# If this is the last line of the certificate, actually do
	# something with it.
	#
	if (/END CERTIFICATE/) {
		#
		# Have we seen this blob before?  If so, close (and delete) the
		# temporary file, and go and look for a new certificate to process.
		#
		$total_certs++;
		if (defined($blobs{$blob})) {
			# print "skipping a blob\n";
			close $fh;
			next;
		}
		
		#
		# Otherwise, remember this blob so that we won't process it again.
		#
		$blobs{$blob} = 1;
		$distinct_certs++;

		#
		# Don't close the temporary file yet, because that would cause it
		# to be deleted.  We've already arranged for buffering to be
		# disabled, so the file can simply be passed to other applications
		# as input, perhaps multiple times.
		#
		
		#
		# Collection of names this certificate contains
		#
		my %names;
		
		#
		# Use openssl to convert the certificate to text
		#
		my(@lines, $subject, $issuer, $subjectCN, $issuerCN, $fingerprint);
		$cmd = "openssl x509 -in $filename -noout -text -nameopt RFC2253 -modulus -fingerprint|";
		open(SSL, $cmd) || die "could not open openssl subcommand";
		while (<SSL>) {
			push @lines, $_;

			if (/^\s*Issuer:\s*(.*)$/) {
				$issuer = $1;
				if ($issuer =~ /CN=([^,]+)/) {
					$issuerCN = $1;
				} elsif ($issuer =~ /,OU=VeriSign International Server CA - Class 3,/) {
					$issuerCN = 'VeriSign International Server CA - Class 3';
				} else {
					$issuerCN = $issuer;
				}
				next;
			}
			
			if (/^\s*Subject:\s*(.*)$/) {
				$subject = $1;
				if ($subject =~ /CN=([^,]+)/) {
					$subjectCN = $1;
					$names{lc $subjectCN}++;
				} else {
					$subjectCN = $1;
				}
				next;
			}
			
			#
			# Extract the certificate fingerprint.
			#
			if (/^\s*SHA1 Fingerprint=(.+)$/) {
				$fingerprint = uc $1;
				if (defined($expiry_whitelist{$fingerprint})) {
					$expiry_whitelist{$fingerprint} = 'used';
				}
			}

			#
			# Extract the public key size.  This is displayed differently
			# in different versions of OpenSSL.
			#
			if (/RSA Public Key: \((\d+) bit\)/) { # OpenSSL 0.9x
				$pubSize = $1;
				next;
			} elsif (/^\s*Public-Key: \((\d+) bit\)/) { # OpenSSL 1.0
				$pubSize = $1;
				next;
			}
			
			if (/Not After : (.*)$/) {
				$notAfter = $1;
				$notAfterTime = str2time($notAfter);

				#
				# Track certificate expiry year in a way that doesn't
				# involve Unix epoch overflow.
				#
				if ($notAfter =~ /(\d\d\d\d)/) {
					my $year = $1;
					$expiryYear = $year;
					if ($year > $maxYear) {
						$maxYear = $year;
					}
					if ($year >= 2038) {
						$num2038++;
					}
				}

				#
				# Track most distant notAfter.
				#
				if ($notAfterTime > $lastNotAfterTime) {
					$lastNotAfter = $notAfter;
					$lastNotAfterTime = $notAfterTime;
					$lastNotAfterEntity = $entity;
				}

				$days = ($notAfterTime-time())/86400.0;
				next;
			}

			#
			# subjectAlternativeName
			#
			if (/X509v3 Subject Alternative Name:/) {
				#
				# Steal the next line, which will look like this:
				#
				#    DNS:www.example.co.uk, DNS:example.co.uk, URI:http://example.co.uk/
				#
				my $next = <SSL>;
				
				#
				# Make an array of components, each something like "DNS:example.co.uk"
				#
				$next =~ s/\s*//g;
				my @altNames = split /\s*,\s*/, $next;
				# my $altSet = "{" . join(", ", @altNames) . "}";
				# print "Alt set: $altSet\n";
				
				#
				# Each "DNS" component is an additional name for this certificate.
				#
				while (@altNames) {
					my ($type, $altName) = split(":", pop @altNames);
					$names{lc $altName}++ if $type eq 'DNS'; 
				}
				next;
			}
			
		}
		close SSL;
		#print "   text lines: $#lines\n";

		#
		# Deal with certificate expiry.
		#
		if ($days < -$longExpiredDays) {
			my $d = floor(-$days);
			if (defined($expiry_whitelist{$fingerprint})) {
				comment("EXPIRED LONG AGO ($d days; $notAfter)");
			} else {
				error("EXPIRED LONG AGO ($d days; $notAfter)");
				comment("fingerprint $fingerprint");
			}
		} elsif ($days < 0) {
			if (defined($expiry_whitelist{$fingerprint})) {
				comment("EXPIRED ($notAfter)");
			} else {
				error("EXPIRED ($notAfter)");
				comment("fingerprint $fingerprint");
			}
		} elsif ($days < $daysBeforeError) {
			$days = int($days);
			error("expires in $days days ($notAfter)");
		} elsif ($days < $daysBeforeWarning) {
			$days = int($days);
			warning("expires in $days days ($notAfter)");
		}


		#
		# Check KeyName if one has been supplied.
		#
		if ($hasKeyName && !defined($names{lc $keyname})) {
			my $nameList = join ", ", sort keys %names;
			error("KeyName mismatch: $keyname not in {$nameList}");
		}
		
		#
		# Use openssl to ask whether this matches our trust fabric or not.
		#
		my $error = '';
		$serverOK = 1;
		$cmd = "openssl verify -CAfile ../mdx/uk/authorities.pem -purpose sslserver $filename |";
		open(SSL, $cmd) || die "could not open openssl subcommand 2";
		while (<SSL>) {
			chomp;
			if (/error/) {
				$error = $_;
				$serverOK = 0;
			}
		}
		close SSL;
		$clientOK = 1;
		$cmd = "openssl verify -CAfile ../mdx/uk/authorities.pem -purpose sslclient $filename |";
		open(SSL, $cmd) || die "could not open openssl subcommand 3";
		while (<SSL>) {
			chomp;
			if (/error/) {
				$error = $_;
				$clientOK = 0;
			}
		}
		close SSL;
		
		#
		# Irrespective of what went wrong, client and server results should match.
		#
		if ($clientOK != $serverOK) {
			error("client/server purpose result mismatch: $clientOK != $serverOK");
		}
		
		#
		# Reduce error if possible.
		#
		if ($error =~ m/^error \d+ at \d+ depth lookup:\s*(.*)$/) {
			$error = $1;
		}
		
		#
		# Now, adjust for our expectations.
		#
		if (!$hasKeyName) {
			#
			# Pretty much any certificate is fine if we don't have a KeyName.
			#
			if ($error eq 'self signed certificate') {
				$error = '';
				comment("self signed certificate");
			} elsif ($error eq 'unable to get local issuer certificate') {
				$error = '';
				comment("unknown issuer: $issuerCN");
			} elsif ($clientOK) {
				# $error = "certificate matches trust fabric; add KeyName?";
			}
		} else {
			#
			# If a KeyName is present, we must match the trust fabric.
			#
			if ($error eq 'self signed certificate') {
				$error = 'self signed certificate: remove KeyName?';
			} elsif ($error eq 'unable to get local issuer certificate') {
				$error = "non trust fabric issuer: $issuerCN: remove KeyName?";
			}

			#
			# KeyName with an expired certificate indicates some kind of misconfiguration.
			# Either the KeyDescriptor isn't working, or the expired certificate is still
			# in use (in which case the KeyName is superfluous) or a different certificate
			# is in use via PKIX (which means we have the wrong one).
			#
			if ($days < 0) {
				error("expired certificate has KeyName; acquire/ensure correct certificate and remove KeyName");
			}
		}

		if ($error eq 'certificate has expired' && $days < 0) {
			# an equivalent message has already been issued
			$error = '';
		}

		if ($error ne '') {
			error($error);
		}
		
		#
		# Handle public key size.
		#
		$pubSizeCount{$pubSize}++;
		# print "   Public key size: $pubSize\n";

		#
		# Close the temporary file, which will also cause
		# it to be deleted.
		#
		close $fh;

		#
		# Add a warning for certain issuers.
		#
		if (defined $issuerMark{$issuerCN}) {
			my $mark = $issuerMark{$issuerCN};
			if ($mark eq '?') {
				warning("issuer '$issuerCN' suspect; verify");
			}
		}
		if ($hasKeyName && ($issuerCN =~ /(Global|Veri)Sign/)) {
			warning("issuer \"$issuerCN\" to be retired; certificate expires $notAfter; remove KeyName?");
			$issuerMark{$issuerCN} = '*';
		}
		if ($hasKeyName && ($expiryYear > 2014)) {
			warning("expires $notAfter, which is later than 2014");
		}

		#
		# Count issuers.
		#
		if ($issuer eq $subject) {
			$issuers{'(self-signed certificate)'}++;
		} else {
			if ($verboseIssuers) {
				$issuers{$issuer}++;
			} else {
				$issuers{$issuerCN}++;
			}
			if ($hasKeyName) {
				$knIssuers{$issuerCN}++;
			}
		}

		#
		# Print any interesting things related to this certificate.
		#
		if ($printme || !$quiet) {
			foreach $oline (@olines) {
				print $oline, "\n";
			}
			print "\n";
		}

	}
}

if ($distinct_certs > 1) {
	print "Total certificates: $total_certs\n";
	if ($distinct_certs != $total_certs) {
		print "Distinct certificate/entity combinations: $distinct_certs\n";
	}
	print "\n";

	print "Key size distribution:\n";
	for $pubSize (sort keys %pubSizeCount) {
		$count = $pubSizeCount{$pubSize};
		print "   $pubSize: $count\n";
	}
	print "\n";

	print "Most distant certificate expiry: $lastNotAfter on $lastNotAfterEntity\n";
	print "Maximum certificate expiry year: $maxYear\n";
	if ($num2038 > 0) {
		print "Certificates expiring during or after 2038: $num2038\n";
	}
	print "\n";

	print "Certificate issuers:\n";
	foreach $issuer (sort keys %issuers) {
		my $count = $issuers{$issuer};
		my $mark = $issuerMark{$issuer} ? $issuerMark{$issuer}: ' ';
		print " $mark $issuer: $count\n";
	}
	print "\n";

	print "KeyName certificate issuers:\n";
	foreach $issuer (sort keys %knIssuers) {
		my $count = $knIssuers{$issuer};
		my $mark = $issuerMark{$issuer} ? $issuerMark{$issuer}: ' ';
		print " $mark $issuer: $count\n";
	}
	print "\n";

	my $first = 1;
	foreach $fingerprint (sort keys %expiry_whitelist) {
		if ($expiry_whitelist{$fingerprint} eq 'unused') {
			if ($first) {
				$first = 0;
				print "\n";
				print "Unused expiry whitelist fingerprints:\n";
			}
			print "   $fingerprint\n";
		}
	}
}
