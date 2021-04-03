#!/usr/bin/perl
#
# This script is used to find feature branches that are behind develop, release branches that are ahead of develop and dead release branches
#
use strict;
use warnings;
use Cwd;

# Needed to make LWP work on ubuntu
$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

my $USE_MERGE_TO_BRANCH = 1;
my $USE_MERGE_FROM_BRANCH = 2;

#
# Get command line inputs
#
my $dryrun = 0;
my ($slack_url, $channel, $mergeOnly) = @ARGV;
if ($slack_url =~ /dryrun/i) {
	$dryrun = 1;
	$slack_url = "";
	$channel = "";
}

if ($mergeOnly =~ /merge.*only/i) {
	$mergeOnly = 1;
} else {
	$mergeOnly = 0;
}

if (!$dryrun) {
	#Slack webhook for sending messages
	if (not defined $slack_url) {
		die "Need the slack webhook url\n";
	}

	if (not defined $channel) {
		die "Need the slack channel to post to\n";
	}
}


#
# Get up to date with origin, and find all branches
#
my $pull = "git pull";
my $listBranches = "git branch -r";
#this prune command will find all active branches on the origin and remove stale ones on the host
my $prune = "git checkout develop; git remote prune origin; git branch -vv | grep ': gone]' | awk '{print \$1}' | xargs git branch -D;";

my $output = `$pull 2>&1`;
$output = `$prune`;
print "$output";

$output = `$listBranches 2>&1`;
my @branches = split /\n/, $output;
my %features = ();
my %releasesAheadOfDevelop = ();
my %unmergedReleases = ();
my %deadReleases = ();
my @hotfixes;
my @releases;
my $betaInternal =  '';
my $betaMaster = '';

#
# Get all release, hotfix and feature branches
#
#for each branch....
foreach my $branch (@branches) {
	#add all feature branches, release branches and hotfix branches to maps
	if ($branch =~ /^\s*origin\/(feature.*)\s*/) {
		my $feature = $1;
		#we only care about feature branches that are behind develop
		$output = `git rev-list origin/$feature..origin/develop --count 2>&1`;
		$output =~ s/\s*(\S*)\s/$1/;
		if ($output > 0) {
			$features{$feature} = $output
		}
	} elsif ($branch =~ /\s*(release.*)\s*/) {
		my $release = $1;
		push @releases, $release;
	} elsif ($branch =~ /\s*(hotfix.*)\s*/) {
		my $hotfix = $1;
		push @hotfixes, $hotfix;
	} elsif ($branch =~ /\s*(beta\/internal)\s*/) {
		$betaInternal = $1;
	}
	elsif ($branch =~ /\s*(beta\/master)\s*/) {
		$betaMaster = $1;
	}
 }

#
# Start merging
#

#
# Merge master into all hotfix branches
# Merge hotfixes into all release branches
#
my $message = "";
if (scalar @hotfixes > 0) {
	#first merge master into hotfix
	foreach my $hotfix (@hotfixes) {
		$message .= mergeIfNeeded($hotfix, 'master');
	}

	#if a hotfix ahead of a release, attempt a merge
	print "Checking all hotfixes vs all release\n";
	foreach my $hotfix (@hotfixes) {
		foreach my $release (@releases) {
			$message .= mergeIfNeeded($release, $hotfix);
		}
	}
}

#
# Merge master into release branches
# Merge all release branches into beta/master
# Check for releases ahead of develop and dead releases (ie not ahead of master)
#
if (scalar @releases > 0) {
	foreach my $release (@releases) {
		$message .= mergeIfNeeded($release, 'master');
		if ($betaMaster ne '') {
			$message .= mergeIfNeeded($betaMaster, $release);
		}
	}

	foreach my $release (@releases) {
		print "Checking all releases vs develop\n";
		$output = isBranchAhead('develop', $release);
		if ($output > 0) {
			$releasesAheadOfDevelop{$release} = $output;
		}

		$output = isBranchAhead('master', $release);
		if (!$output) {
			$deadReleases{$release} = $output;
		}
	}
}


#
# Merge all release branches into develop
#
my $size = keys %releasesAheadOfDevelop;
if ($size > 0) {
	my $releaseMessage = "";
	foreach my $release (keys %releasesAheadOfDevelop) {
		print "Attempting to merge $release to develop\n";
		$output = merge("develop", $release);
		if ($output) {
			$releaseMessage .= $output;
			$unmergedReleases{$release} = $releasesAheadOfDevelop{$release};
		}
	}

	if (keys %unmergedReleases > 0) {
		$releaseMessage .= "\n*RELEASES - Please merge these branches into develop*\n";
		foreach my $release (keys %unmergedReleases) {
			$releaseMessage .= "origin\/$release is $releasesAheadOfDevelop{$release} commits ahead of origin\/develop\n";
		}
	}

	if (length($releaseMessage) > 0) {
		$message .= "\n*RELEASES - Merging open release branches into develop*\n";
		$message .= $releaseMessage;
	}
}

#
# Merge beta/master into beta/internal
#
if ($betaInternal && $betaMaster) {
	$message .= mergeIfNeeded($betaInternal, $betaMaster);
}

#
# Merge master into develop just in case there are no release branches
#
$message .= mergeIfNeeded('develop', 'master');

#
# Check for release branches that are not ahead of master to notify the team
#
$size = keys %deadReleases;
if ($size > 0 && !$mergeOnly) {
	$message .= "\n*DEAD RELEASES - Should these branches be deleted*\n";
	foreach my $release (keys %deadReleases) {
		$message .= "origin\/$release is 0 commits ahead of origin\/master.\n";
	}
}

#
# Notify the team if we should merge develop into feature branches
#
$size = keys %features;
#add the message specifying how many commits behind develop the feature branch is
if ($size > 0 && !$mergeOnly) {
	$message .= "\n*FEATURES - Please merge develop into these branches*\n";
	foreach my $feature (keys %features) {
		$message .= "origin\/$feature is $features{$feature} commits behind origin\/develop\n";
	}
}

#
# Send the message to slack
#
if (length($message) > 0) {
	my @split = split /\//, getcwd();
	$message = "*Merge bot for " . $split[@split - 1] . "*\n" . $message;

	print "$message\n";

	#convert new lines to literal \n
	$message =~ s/\n/\\n/g;

	my $json = "{\"text\": \"$message\", \"username\": \"ss-merge-bot\", \"channel\":\"$channel\"}";

	print "$json\n";
	if (!$dryrun) {
		my $responseCode = system("curl -X POST -H 'Content-type: application/json' --data \'$json\' $slack_url 2>&1");
		if ($responseCode == 0) {
			print("SUCCESSFUL post!\n");
		}
		else {
			print("ERROR: " . $responseCode);
		}
	}
} else {
	print "Everything is up to date.\n";
}


#attempt trivial merge between two branches
sub merge {
	my $merge_to = $_[0];
	my $merge_from = $_[1];
	my $dryrun = $_[2];
	my $original_branch = currentBranch();
	print "Merging to $merge_to from $merge_from\n";
	if (!checkout($merge_to)) {
		return "*ERROR COULD NOT MERGE $merge_from into $merge_to! Failed to checkout $original_branch*\n";
	}

	print "git merge -m \"Merged to $merge_to from $merge_from\" origin\/$merge_from\n";
	my $ret = system("git merge -m \"Merged to $merge_to from $merge_from\" origin\/$merge_from");
	if ($ret != 0) {
		#get all merge conflict information
		my $conflictedData = `git diff --diff-filter=U`;
		$ret = handleVersionMergeConflicts($conflictedData);
		if ($ret =~ /^Error/) {
			$output = `git reset --hard HEAD`;
			checkout($original_branch);
			print "*ERROR COULD NOT MERGE $merge_from into $merge_to!*\nPlease Check for merge conflicts!\n";
			return "*ERROR COULD NOT MERGE $merge_from into $merge_to!*\nPlease Check for merge conflicts!\n";
		}
		elsif ($ret == $USE_MERGE_TO_BRANCH) {
			#--ours is the merge to branch
			$output = `git reset --hard HEAD`;
			$output = `git merge origin/$merge_from -Xours`;
			print "Fixed version conflict used OURs\n";
		}
		elsif ($ret == $USE_MERGE_FROM_BRANCH) {
			#--theirs is the merge from branch
			$output = `git reset --hard HEAD`;
			$output = `git merge origin/$merge_from -Xtheirs`;
			print "Fixed version conflict used THEIRS\n";
		}
	}

	print "Pushing...\n";
	if ($dryrun) {
		print "Dryrun, this is where we would push\n";
		$output = "Your branch is up to date with 'origin/$merge_to'";
	}
	else {
		$output = `git push`;
		$output = `git status`;
	}

	print "Status after merge...$output\n";
	if ($output =~ /Your branch is up to date with 'origin\/\Q$merge_to'/) {
		checkout($original_branch);
		return 0;
	}
	else {
		print "Failed...resetting\n";
		`git reset --hard origin/$merge_to`;
		print "Checking out $original_branch\n";
		checkout($original_branch);
		return "There was an issue merging $merge_from into $merge_to. Please manually merge!\n";
	}
}


sub currentBranch {
	my $output = `git status 2>&1`;
	$output =~ s/^On branch\s+(\S+)/$1/;
	return $1;
}

sub checkout {
	my $branch = $_[0];
	print "git checkout $branch\n";


	my $output = `git checkout $branch 2>&1`;
	my $current = currentBranch();

	if ($branch =~ /\Q$current/) {
		return 1;
	}
	die "Failed to checkout $branch\n";
}

sub isBranchAhead {
    my $merge_to = $_[0];
    my $merge_from = $_[1];

    $output = `git rev-list origin/$merge_to..origin/$merge_from --count 2>&1`;
    $output =~ s/\s*(\S*)\s/$1/;
    return $output;
}

sub mergeIfNeeded {
	my $merge_to = $_[0];
	my $merge_from = $_[1];
	my $dryrun = $_[2];

	my $slackMessage = "";
	print "Checking to see if $merge_from needs to merge into $merge_to\n";
	if (isBranchAhead($merge_to, $merge_from)) {
		$output = merge($merge_to, $merge_from, $dryrun);
		if ($output) {
			$slackMessage .= "ERROR: There was an issue merging $merge_from into $merge_to. Please manually merge!\n";
		} else {
			$slackMessage .= "Merging *$merge_from* into *$merge_to*\n";
		}
	}

	return $slackMessage;
}

sub handleVersionMergeConflicts {
	my $conflictedData = $_[0];
	#constants for the state machine
	my $SEARCHING_FOR_CONFLICT_START = 1;
	my $SEARCHING_FOR_HEAD_VERSION = 2;
	my $SEARCHING_FOR_OTHER_VERSION = 3;
	my $SEARCHING_FOR_CONFLICT_END = 4;

	my @lines = split("\n", $conflictedData);
	my $state = $SEARCHING_FOR_CONFLICT_START;
	my $mergeToVersion = "";
	my $mergeFromVersion = "";
	foreach my $line (@lines) {
		print "$state $line\n";
		#        ++<<<<<<< HEAD
		#         +      <string>2076.0.2</string>
		#        ++=======
		#        +       <string>2074.63.0</string>
		#        ++>>>>>>> beta/master
		#        versionCode 20366
		#        versionName "3.52.0"
		if ($state == $SEARCHING_FOR_CONFLICT_START) {
			if ($line =~ /^\s*\+\+<<<<<<< HEAD/) {
				$state = $SEARCHING_FOR_HEAD_VERSION;
				print "Found conflict <<<<<\n";
			}
		} elsif ($state == $SEARCHING_FOR_HEAD_VERSION) {
			if ($line =~ /(\d+\.\d+\.\d+)/) {
				$mergeToVersion = $1;
				$state = $SEARCHING_FOR_OTHER_VERSION;
				print ("Found version in merge TO branch $mergeToVersion\n");
			} elsif ($line !~ /versionCode/) {
				print "Error: Found a merge conflict that is not just a version conflict (3)\n$line\n";
				return "Error: Found a merge conflict that is not just a version conflict (1)\n$line\n";
			}
		} elsif ($state == $SEARCHING_FOR_OTHER_VERSION) {
			if ($line =~ /(\d+\.\d+\.\d+)/) {
				$mergeFromVersion = $1;
				$state = $SEARCHING_FOR_CONFLICT_END;
				print ("Found version in merge FROM branch $mergeFromVersion\n");
			} elsif ($line !~ /versionCode/ && $line !~ /=======/) {
				print "Error: Found a merge conflict that is not just a version conflict (3)\n$line\n";
				return "Error: Found a merge conflict that is not just a version conflict (2)\n$line\n";
			}
		} elsif ($state == $SEARCHING_FOR_CONFLICT_END) {
			if ($line =~ /\>\>\>\>\>\>\>/) {
				$state = $SEARCHING_FOR_CONFLICT_START;
			} elsif ($line !~ /versionCode/) {
				print "Error: Found a merge conflict that is not just a version conflict (3)\n$line\n";
				return "Error: Found a merge conflict that is not just a version conflict (3)\n$line\n";
			}
		}
	}

	if (!$mergeToVersion || !$mergeFromVersion) {
		return "Error: Found a merge conflict without any version information\n";
	}

	if ($mergeToVersion gt $mergeFromVersion) {
		print "Selected $mergeToVersion the branch we are merging to\n";
		return $USE_MERGE_TO_BRANCH;
	} else {
		print "Selected $mergeFromVersion the branch we are merging from\n";
		return $USE_MERGE_FROM_BRANCH;
	}
}