#! perl

##
# ログファイルを読んでユーザ定義のなんらかの処理を行います（swatchみたいなもん）。
# 
# 起動するとログファイルを末尾から走査し、最終行を一時ファイルにメモします。
# ２回目以降に起動するときは、メモされた前回の最終行までのみ走査することで走査時間を短縮します。
# 典型的にはcrontabなどから定期的に起動されることを想定しています。
# 
# なお、このスクリプトが動作するためには、個別処理を定義したプラグインが必要です。
# このスクリプトと同じディレクトリに "logpoller-${LOG_TYPE}.pl" というファイル名で設置して下さい。
# 書き方はサンプルを見て下さい。
# 
# このコード内の用語
#   物理行           …ログファイルのテキスト一行のこと。
#   ログ行           …ログは複数行になっている場合があります。論理的なログの1個分のこと。
#   LogUnit          …ログ行のこと。
#   ヘッダ           …ログ行の先頭の物理行のこと。物理行はヘッダ単位でLogUnitとして管理されます。
#   最終ダイジェスト …ログ行のMD5。前回起動時の最終ログ行をメモしておくために使われます。
##
package logpoller;

use strict;
use warnings;
use utf8;
use Getopt::Long;
use Time::Local;
use Digest::MD5 qw(md5_hex);
use File::Basename;
use lib dirname($0);

_init_plugin();

my %options;
GetOptions(
  \%options,
  "mailto:s",
  "target-file:s",
  "sendmail-path:s",
  "last-digest-file:s",
  "bound-date:i",
  "bound-count:i",
  "log-type:s",
  logpoller_plugin::optdef()
);

my $LOG_TYPE;        # @see _init_plugin
my $MAILTO           = $options{'mailto'};
my $TARGET_FILE      = $options{'target-file'} || die('--target-file option needed.');
my $SENDMAIL_PATH    = $options{'sendmail-path'} || '/usr/sbin/sendmail';
my $BOUND_DATE       = $options{'bound-date'} || 999999999;
my $BOUND_COUNT      = $options{'bound-count'} || 999999999;
my $LAST_DIGEST_FILE = $options{'last-digest-file'} || "/tmp/logpoller-digest-$LOG_TYPE.txt";

main: {
  # プラグインの初期化処理
  logpoller_plugin::init();
  
  # 前回の起動時ののログファイルの最終ダイジェスト
  my $lastDigest = '';
  if(open(OLD, $LAST_DIGEST_FILE)){
    $lastDigest = <OLD> || '';
    close OLD;
  }

  # ターゲットのログファイルを開きます
  open(FILE, "tac '$TARGET_FILE' |") || die($!);

  # ログファイルを下の行から順に読む
  my $count = 0;
  my $logUnit = [];           # ログ行
  my @handledLogs = ();       # 処理対象となったLogUnitのリスト
  my $currentLastDigest = ""; # 最終ダイジェスト
  while (my $line = <FILE>) {
    unshift(@$logUnit, $line);
    
    # ヘッダを区切りにLogUnitを入れ替えます
    if (logpoller_plugin::log_header_matches($line)) {
      my $logDigest = md5_hex( join('', @$logUnit));
      
      # 最終ダイジェストをメモリに確保する
      if (! $currentLastDigest) {
        $currentLastDigest = $logDigest;
      }
      
      # 前回記録したログ行まで達したらループを抜けて終了。
      if ($logDigest eq $lastDigest) {
        last;
      }
      
      # 処理対象か調べる
      if (logpoller_plugin::log_will_be_handled($logUnit)) {
        push(@handledLogs, $logUnit);
      }
      
      # 日付範囲か調べる。超えてたらループ抜けて終了。
      if (! _is_bound_date( logpoller_plugin::log_date($logUnit))) {
        last;
      }
      
      # 上限ログ行数範囲か調べる。超えてたらループ抜けて終了。
      $count++;
      if ($count >= $BOUND_COUNT) {
        last;
      }
      
      $logUnit = [];
    }
  }

  # 最終ダイジェストに更新があればLAST_DIGEST_FILEに記録
  if ($currentLastDigest ne $lastDigest) {
    open(OLD2, ">$LAST_DIGEST_FILE") || die($!);
    print OLD2 $currentLastDigest;
    close OLD2;
    chmod 0666, $LAST_DIGEST_FILE;
  }

  # なんらかの処理を行う
  if (@handledLogs) {
    logpoller_plugin::log_handle(@handledLogs);
  }
}

##
# MAILTOへメールを送る
# @param string subject メールのタイトル
# @param ARRAYREF handledLogs LogUnitのリスト
##
sub log_handle_sendmail {
  my($subject, @handledLogs) = @_;
  
  if (! $MAILTO) {
    die('--mailto option needed.');
  }
  
  my $mailBody = '';
  foreach my $unit (@handledLogs) {
    $mailBody .= join('', @$unit);
  }
  
  open(MAIL, "| '$SENDMAIL_PATH' -t -i") || die($!);
  print MAIL "To: $MAILTO"."\x0D\x0A";
  print MAIL "Subject: $subject"."\x0D\x0A";
  print MAIL "\x0D\x0A";
  print MAIL $mailBody;
  close MAIL;
}

##
# オプション取得
##
sub getopt {
  my($name) = @_;
  return $options{$name};
}

##
# プラグインのロード
##
sub _init_plugin {
  # まずログタイプだけ判定する
  foreach my $it (@ARGV) {
    if ($it =~ m/--log-type=(\w+)/) {
      $LOG_TYPE = $1;
    }
  }
  
  if (! $LOG_TYPE) {
    die("--log-type option needed.");
  }

  # ログタイプに応じたプラグインのロード
  eval {
    require("logpoller-$LOG_TYPE.pl");
  }; if ($@) {
    die "failed to load plugin: $LOG_TYPE";
  }
}

##
# BOUND_DATE以内かどうかを調べる
# @return boolean BOUND_DATE以内であれば真
##
sub _is_bound_date {
  my($year, $month, $mday, $hour, $min, $sec) = @_;
  
  my $t = timelocal($sec, $min, $hour, $mday, $month-1, $year-1900);
  if ($t < time()-($BOUND_DATE*60*60*24)) {
    return 0;
  }
  
  return 1;
}