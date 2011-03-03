#! perl

##
# logpollerの個別対応処理です。
#
# AdvancedLoggerのDino改造版ログに対応しました。
##
package logpoller_plugin;

use strict;
use warnings;

my $HDR_REGEXP = qr%^\[\d+-\d+-\d+ \d+:\d+:\d+\] (emerg|alert|crit|err|warning|notice|info|debug) %;
my %LEVEL2NUM = (
  emerg   => 0,
  alert   => 1,
  crit    => 2,
  err     => 3,
  warning => 4,
  notice  => 5,
  info    => 6,
  debug   => 7
);
my $SITE_NAME;
my $HANDLE_LEVEL;

##
# コマンドラインオプションの追加定義
# @see GetOptions
# @example "temp-file=s"
# @return ARRAY
##
sub optdef {
  return (
    'site-name:s',
    'handle-level:s'
  );
}

##
# プラグインの初期化処理
# @return void
##
sub init {
  $SITE_NAME    = logpoller::getopt('site-name') || 'SITE';
  $HANDLE_LEVEL = logpoller::getopt('handle-level') || 0;
}

##
# この物理行はヘッダか？
# @param string logLine ログの物理行
# @return boolean ヘッダであるなら真
##
sub log_header_matches {
  my($logLine) = @_;
  return ($logLine =~ $HDR_REGEXP);
}

##
# ログ行の日時を解析して返します。
# bound-dateオプションで参照されます。無視するなら適当な固定値を渡して下さい。
# @param ARRAYREF LogUnit ログ行データ。[0]がヘッダです。
# @return ARRAY ($year, $month, $mday, $hour, $min, $sec)
##
sub log_date {
  my($logUnit) = @_;
  return (2030, 12, 31, 23, 59, 59);
}

##
# ログ行を処理対象とするかを判定する
# @param ARRAYREF LogUnit ログ行データ。[0]がヘッダです。
# @return boolean 処理対象なら真
##
sub log_will_be_handled {
  my($logUnit) = @_;
  my $header = $logUnit->[0];
  
  if ($header =~ $HDR_REGEXP) {
    my $levelNum = $LEVEL2NUM{$1};
    return ($HANDLE_LEVEL >= $levelNum);
  }
}

##
# ログ行を処理する
# @param ARRAYREF handledLogs LogUnitのリスト。新しい（ログファイルの末尾を先頭とした）順に並んでいます。
# @return void
##
sub log_handle {
  my(@handledLogs) = @_;
  
  my $hostname = `hostname`;
  chomp($hostname);
  my $subject = "$SITE_NAME ALERT [$hostname]";
  
  logpoller::log_handle_sendmail($subject, @handledLogs);
}

1;