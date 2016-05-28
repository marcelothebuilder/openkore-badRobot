#############################################################################
# badRobot plugin by revok/marcelofoxes
#
# Usage:
# attackAuto_steal <boolean flag>
#	1 : Don't check if we are kill stealing
#   0 or unset : Default OpenKore check
#
# itemsGatherAuto_steal <boolean flag>
#	1 : Don't check if the item is near a player (this check is to avoid looting)
#   0 or unset : Default OpenKore check
#																			
# You should not use or redistribute this code without permission.
#
# ATTENTION: This plugin is not affiliated nor have any relation with any
#            OpenKore or Ragnarök Online related website.
#
#############################################################################
package badRobot;

use strict;
use Globals;
#use Log qw(message warning error debug);

use Log qw(message warning error debug);

use Misc;
use Settings;
use AI;
use Utils;
use Commands;
use Network;
use FileParsers;
use Field;
use Task::TalkNPC;
use Utils::Exceptions;

# Plugin
Plugins::register('badRobot', "we love to steal your monsters !");

*Misc::checkMonsterCleanness =
*AI::checkMonsterCleanness =
*AI::CoreLogic::checkMonsterCleanness =
*AI::Attack::checkMonsterCleanness =
*AI::Slave::checkMonsterCleanness =
sub {
	return 1 if ($config{attackAuto_steal});
	
	return 1 if (!$config{attackAuto});
	my $ID = $_[0];
	return 1 if $playersList->getByID($ID) || $slavesList->getByID($ID);
	my $monster = $monstersList->getByID($ID);

	# If party attacked monster, or if monster attacked/missed party
	if ($monster->{dmgFromParty} > 0 || $monster->{missedFromParty} > 0 || $monster->{dmgToParty} > 0 || $monster->{missedToParty} > 0) {
		return 1;
	}

	if ($config{aggressiveAntiKS}) {
		# Aggressive anti-KS mode, for people who are paranoid about not kill stealing.

		# If we attacked the monster first, do not drop it, we are being KSed
		return 1 if ($monster->{dmgFromYou} || $monster->{missedFromYou});
		
		# If others attacked the monster then always drop it, wether it attacked us or not!
		return 0 if (($monster->{dmgFromPlayer} && %{$monster->{dmgFromPlayer}})
			  || ($monster->{missedFromPlayer} && %{$monster->{missedFromPlayer}})
			  || (($monster->{castOnByPlayer}) && %{$monster->{castOnByPlayer}})
			  || (($monster->{castOnToPlayer}) && %{$monster->{castOnToPlayer}}));
	}
	
	# If monster attacked/missed you
	return 1 if ($monster->{'dmgToYou'} || $monster->{'missedYou'});

	# If we're in follow mode
	if (defined(my $followIndex = AI::findAction("follow"))) {
		my $following = AI::args($followIndex)->{following};
		my $followID = AI::args($followIndex)->{ID};

		if ($following) {
			# And master attacked monster, or the monster attacked/missed master
			if ($monster->{dmgToPlayer}{$followID} > 0
			 || $monster->{missedToPlayer}{$followID} > 0
			 || $monster->{dmgFromPlayer}{$followID} > 0) {
				return 1;
			}
		}
	}

	if (objectInsideSpell($monster)) {
		# Prohibit attacking this monster in the future
		$monster->{dmgFromPlayer}{$char->{ID}} = 1;
		return 0;
	}

	#check party casting on mob
	my $allowed = 1; 
	if (scalar(keys %{$monster->{castOnByPlayer}}) > 0) 
	{ 
		foreach (keys %{$monster->{castOnByPlayer}}) 
		{ 
			my $ID1=$_; 
			my $source = Actor::get($_); 
			unless ( existsInList($config{tankersList}, $source->{name}) || 
				($char->{party} && %{$char->{party}} && $char->{party}{users}{$ID1} && %{$char->{party}{users}{$ID1}})) 
			{ 
				$allowed = 0; 
				last; 
			} 
		} 
	} 

	# If monster hasn't been attacked by other players
	if (scalar(keys %{$monster->{missedFromPlayer}}) == 0
	 && scalar(keys %{$monster->{dmgFromPlayer}})    == 0
	 #&& scalar(keys %{$monster->{castOnByPlayer}})   == 0	#change to $allowed
	&& $allowed

	 # and it hasn't attacked any other player
	 && scalar(keys %{$monster->{missedToPlayer}}) == 0
	 && scalar(keys %{$monster->{dmgToPlayer}})    == 0
	 && scalar(keys %{$monster->{castOnToPlayer}}) == 0
	) {
		# The monster might be getting lured by another player.
		# So we check whether it's walking towards any other player, but only
		# if we haven't already attacked the monster.
		if ($monster->{dmgFromYou} || $monster->{missedFromYou}) {
			return 1;
		} else {
			return !objectIsMovingTowardsPlayer($monster);
		}
	}

	# The monster didn't attack you.
	# Other players attacked it, or it attacked other players.
	if ($monster->{dmgFromYou} || $monster->{missedFromYou}) {
		# If you have already attacked the monster before, then consider it clean
		return 1;
	}
	# If you haven't attacked the monster yet, it's unclean.

	return 0;
};

*AI::CoreLogic::processItemsGather =
sub {
	if (AI::action eq "items_gather" && AI::args->{suspended}) {
		AI::args->{ai_items_gather_giveup}{time} += time - AI::args->{suspended};
		delete AI::args->{suspended};
	}
	if (AI::action eq "items_gather" && !($items{AI::args->{ID}} && %{$items{AI::args->{ID}}})) {
		my $ID = AI::args->{ID};
		message sprintf("Failed to gather %s (%s) : Lost target\n", $items_old{$ID}{name}, $items_old{$ID}{binID}), "drop";
		AI::dequeue;

	} elsif (AI::action eq "items_gather") {
		my $ID = AI::args->{ID};
		my ($dist, $myPos);

		if ((positionNearPlayer($items{$ID}{pos}, 12)) && !$config{itemsGatherAuto_steal}) {
			message sprintf("Failed to gather %s (%s) : No looting!\n", $items{$ID}{name}, $items{$ID}{binID}), undef, 1;
			AI::dequeue;

		} elsif (timeOut(AI::args->{ai_items_gather_giveup})) {
			message sprintf("Failed to gather %s (%s) : Timeout\n", $items{$ID}{name}, $items{$ID}{binID}), undef, 1;
			$items{$ID}{take_failed}++;
			AI::dequeue;

		} elsif ($char->{sitting}) {
			AI::suspend();
			stand();

		} elsif (( $dist = distance($items{$ID}{pos}, ( $myPos = calcPosition($char) )) > 2 )) {
			if (!$config{itemsTakeAuto_new}) {
				my (%vec, %pos);
				getVector(\%vec, $items{$ID}{pos}, $myPos);
				moveAlongVector(\%pos, $myPos, \%vec, $dist - 1);
				$char->move(@pos{qw(x y)});
			} else {
				my $item = $items{$ID};
				my $pos = $item->{pos};
				message sprintf("Routing to (%s, %s) to take %s (%s), distance %s\n", $pos->{x}, $pos->{y}, $item->{name}, $item->{binID}, $dist);
				ai_route($field->baseName, $pos->{x}, $pos->{y}, maxRouteDistance => $config{'attackMaxRouteDistance'});
			}

		} else {
			AI::dequeue;
			take($ID);
		}
	}
};

1;
# i luv u mom
