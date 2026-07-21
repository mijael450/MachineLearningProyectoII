#!/usr/bin/env perl
use strict;use warnings;use lib '.';use Test::More;
use Market::MarketData;use Market::IndicatorManager;use Market::ReplayProxy;
use Market::Indicators::ATR;use Market::Indicators::SMC_Structures;use Market::Indicators::Liquidity;
use Market::ChartEngine;

my$m=Market::MarketData->new;$m->load_csv_files(qw(2026_04.csv 2026_05.csv 2026_06_29.csv 2026_03.csv));
my$base=$m->get_tf_data(1);my%epoch;$epoch{$_->{epoch}}++for@$base;
is(scalar(@$base),scalar(keys%epoch),'CSV timestamps deduplicated');
for my$tf(1,5,15,60,120,240,'D','W'){ok(@{$m->get_tf_data($tf)}>0,"timeframe $tf available")}
$m->set_timeframe(60);my$i=Market::IndicatorManager->new;$i->register(ATR=>Market::Indicators::ATR->new);
my$smc=Market::Indicators::SMC_Structures->new(depth=>5);my$liq=Market::Indicators::Liquidity->new(depth=>3);
$i->register(SMC_Structures=>$smc);$i->register(Liquidity=>$liq);$i->update_last($m);
my$l=$liq->values;ok(@$l>0,'liquidity levels detected');
ok(grep(($_->{origin}//'')eq'external',@$l),'external HTF liquidity projected');
ok(!grep(!defined($_->{volume_mtf}{1})||!defined($_->{volume_mtf}{5})||!defined($_->{volume_mtf}{15}),@$l),'1m/5m/15m volume persisted');
ok(grep(defined($_->{classification}),@$l),'liquidity state machine resolves events');
my$cursor=600;my$p=Market::WindowProxy->new($m,$cursor,300);$smc->calculate_all($p);$liq->calculate_replay($p);$smc->apply_liquidity_context($liq);
ok(!grep($_->{index}>$cursor||defined($_->{resolved_at})&&$_->{resolved_at}>$cursor,@{$liq->values}),'Replay contains no future liquidity');
ok(!grep(!defined($_->{volume_mtf}{1})||!defined($_->{volume_mtf}{5})||!defined($_->{volume_mtf}{15}),@{$liq->values}),'Replay preserves MTF volume');

# Contrato directo de concurrencia del punto 5.
my$ctx=Market::Indicators::SMC_Structures->new;
$ctx->{events}=[{index=>12,type=>'CHoCH'},{index=>22,type=>'BOS'}];
$ctx->{fvgs}=[{index=>11},{index=>21}];
{ package VerifyLiquidity; sub values { $_[0]{levels} } }
my$fake=bless{levels=>[
 {state=>'Resolved',classification=>'Sweep',swept_at=>10,resolved_at=>11},
 {state=>'Resolved',classification=>'Run',swept_at=>20,resolved_at=>21},
 {state=>'Resolved',classification=>'Grab',swept_at=>30,resolved_at=>31},
]},'VerifyLiquidity';
$ctx->apply_liquidity_context($fake);
is($ctx->{events}[0]{probability_weight},3,'Sweep increases CHoCH weight');
is($ctx->{events}[1]{probability_weight},2,'Run increases BOS weight');
ok($fake->{levels}[2]{reversal_alert},'Grab emits reversal alert');
ok($ctx->{fvgs}[0]{high_reaction},'Sweep-associated FVG marked high reaction');
my$chart=bless{replay_cursor=>50,first=>20,visible=>100,auto_y=>0,auto_atr=>0},'Market::ChartEngine';
$chart->_replay_center_view;is($chart->{first},20,'Replay keeps candles fixed while cursor is visible');
$chart->{replay_cursor}=120;$chart->_replay_center_view;is($chart->{first},21,'Replay scrolls only after right edge');
$chart->{replay_mode}=1;$chart->{replay_playing}=1;$chart->{replay_timer}=undef;
ok($chart->replay_running,'Replay playing state does not depend on timer id');
done_testing;
