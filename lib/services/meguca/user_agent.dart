import 'dart:convert';

import 'package:chan/services/settings.dart';
import 'package:crypto/crypto.dart';

/// Shared signing secret for the Chance User-Agent. Picked up at build time
/// via `--dart-define=CHANCE_UA_SECRET=...`. When unset (e.g. local dev
/// builds), the UA still carries a deterministic signature but the server
/// won't verify it, so HTTP posting falls back to the normal onboarding
/// path. Set the same value on both client and server (`MEGUCA_CHANCE_UA_SECRET`
/// on the server side, see `/root/meguca/auth/chance_ua.go`) to enable the
/// new-user bypass.
const String _chanceUASecret = String.fromEnvironment(
  'CHANCE_UA_SECRET',
  defaultValue: '',
);

/// Mixed into the per-install id derivation so flipping the secret on the
/// server doesn't also force every install to re-roll its identity. Doesn't
/// have to be secret — just stable across builds and obscure enough that
/// scrapers don't trivially reproduce a Chance install_id.
const String _chanceInstallIdSalt = 'chance-install:awoo.cf:v1';

/// Length of the time-bucket window the UA signature rotates within.
/// Must match `chanceBucketSeconds` on the server. 5 minutes is a good
/// trade-off: long enough that mobile clients with poor clocks still hit
/// the same bucket, short enough that a leaked UA stops working before
/// a scraper can put together a useful pipeline.
const int _chanceBucketSeconds = 300;

/// Returns a stable per-install signed user agent in the form
///
///   chance/<install_id>/<bucket>/<sig>
///
/// where `install_id` is 32 hex chars derived deterministically from a
/// persisted install timestamp, `bucket = floor(unix_seconds / 300)`, and
/// `sig` is the first 16 bytes of `HMAC-SHA256(secret, install_id + ":" + bucket)`
/// rendered as hex. The server (`auth.VerifyChanceUA`) recomputes the same
/// signature using the configured `MEGUCA_CHANCE_UA_SECRET` and accepts UAs
/// from the current bucket or one bucket on either side (±5 minutes).
///
/// The signature rotates every 5 minutes so a captured request stops being
/// useful long before anyone can paste it into a scraper, and the secret
/// lives on both sides — open source, but anyone forging UAs would need to
/// keep up with whatever secret your deployment is currently using.
String megucaChanceUserAgent() {
  final settings = Settings.instance;
  var installSeed = settings.owoVgInstallDate;
  if (installSeed == null) {
    installSeed = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    settings.owoVgInstallDate = installSeed;
  }
  final installId = _chanceInstallId(installSeed);
  final bucket = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ _chanceBucketSeconds;
  final sig = _chanceSignature(installId, bucket);
  return 'chance/$installId/$bucket/$sig';
}

String _chanceInstallId(int installSeed) {
  final digest = sha256.convert(utf8.encode('$_chanceInstallIdSalt:$installSeed'));
  final hex = digest.toString();
  return hex.substring(0, 32);
}

String _chanceSignature(String installId, int bucket) {
  final hmacSha256 = Hmac(sha256, utf8.encode(_chanceUASecret));
  final mac = hmacSha256.convert(utf8.encode('$installId:$bucket'));
  final bytes = mac.bytes;
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    final b = bytes[i];
    if (b < 16) buf.write('0');
    buf.write(b.toRadixString(16));
  }
  return buf.toString();
}
