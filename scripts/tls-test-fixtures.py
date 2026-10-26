"""Create an isolated PKI for TLS reload tests; never touches the OS trust store."""
import datetime as dt
import ipaddress
import json
from pathlib import Path
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509 import ocsp
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
pem = serialization.Encoding.PEM
fingerprints = {}


def save(name, key, certificate):
    (root / f"{name}.key").write_bytes(key.private_bytes(
        pem, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    (root / f"{name}.pem").write_bytes(certificate.public_bytes(pem))
    public_key = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    digest = hashes.Hash(hashes.SHA256())
    digest.update(public_key)
    fingerprints[name] = {"cert": certificate.fingerprint(hashes.SHA256()).hex(), "spki": digest.finalize().hex()}


def authority(name):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"ZiServer test {name}")])
    certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - dt.timedelta(days=3)).not_valid_after(now + dt.timedelta(days=3))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
                   .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), True)
                   .sign(key, hashes.SHA256()))
    save(name, key, certificate)
    return key, certificate


def leaf(name, issuer, server=False, expired=False, ocsp_signer=False):
    issuer_key, issuer_cert = issuer
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost" if server else name)])
    builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer_cert.subject)
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - dt.timedelta(days=2))
               .not_valid_after(now - dt.timedelta(days=1) if expired else now + dt.timedelta(days=1))
               .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
               .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.OCSP_SIGNING if ocsp_signer else
                   (ExtendedKeyUsageOID.SERVER_AUTH if server else ExtendedKeyUsageOID.CLIENT_AUTH)]), False))
    if server:
        builder = builder.add_extension(x509.SubjectAlternativeName([
            x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False)
    certificate = builder.sign(issuer_key, hashes.SHA256())
    save(name, key, certificate)
    return key, certificate


def crl(name, issuer, revoked=None, expired=False, signer=None):
    key, certificate = issuer
    builder = (x509.CertificateRevocationListBuilder().issuer_name(certificate.subject)
               .last_update(now - dt.timedelta(days=2) if expired else now - dt.timedelta(minutes=1))
               .next_update(now - dt.timedelta(days=1) if expired else now + dt.timedelta(days=1)))
    if revoked is not None:
        entry = (x509.RevokedCertificateBuilder().serial_number(revoked.serial_number)
                 .revocation_date(now - dt.timedelta(minutes=1))
                 .add_extension(x509.CRLReason(x509.ReasonFlags.key_compromise), False).build())
        builder = builder.add_revoked_certificate(entry)
    (root / name).write_bytes(builder.sign(signer or key, hashes.SHA256()).public_bytes(pem))


def response(name, issuer, certificate, status, stale=False, missing_next=False, signer=None, digest=None):
    key, ca = issuer
    signer_key, signer_cert = signer or issuer
    builder = (ocsp.OCSPResponseBuilder().add_response(
        cert=certificate, issuer=ca, algorithm=digest or hashes.SHA1(), cert_status=status,
        this_update=now - dt.timedelta(days=2) if stale else now - dt.timedelta(minutes=1),
        next_update=None if missing_next else (now - dt.timedelta(days=1) if stale else now + dt.timedelta(hours=1)),
        revocation_time=now - dt.timedelta(minutes=1) if status == ocsp.OCSPCertStatus.REVOKED else None,
        revocation_reason=x509.ReasonFlags.key_compromise if status == ocsp.OCSPCertStatus.REVOKED else None)
        .responder_id(ocsp.OCSPResponderEncoding.HASH, signer_cert).certificates([signer_cert]))
    (root / name).write_bytes(builder.sign(signer_key, hashes.SHA256()).public_bytes(serialization.Encoding.DER))


ca = authority("ca")
other_ca = authority("other-ca")
server_a = leaf("server-a", ca, server=True)
leaf("server-b", ca, server=True)
leaf("expired-server", ca, server=True, expired=True)
client = leaf("client", ca)
second = leaf("second-client", ca)
responder = leaf("ocsp-responder", ca, ocsp_signer=True)
leaf("stranger", other_ca)
crl("empty.crl", ca)
crl("revoked.crl", ca, revoked=client[1])
crl("expired.crl", ca, expired=True)
crl("forged.crl", ca, signer=other_ca[0])
crl("other-empty.crl", other_ca)
response("good.der", ca, client[1], ocsp.OCSPCertStatus.GOOD)
response("good-sha256.der", ca, client[1], ocsp.OCSPCertStatus.GOOD, digest=hashes.SHA256())
response("revoked.der", ca, client[1], ocsp.OCSPCertStatus.REVOKED)
response("unknown.der", ca, client[1], ocsp.OCSPCertStatus.UNKNOWN)
response("expired.der", ca, client[1], ocsp.OCSPCertStatus.GOOD, stale=True)
response("missing-next.der", ca, client[1], ocsp.OCSPCertStatus.GOOD, missing_next=True)
response("forged.der", ca, client[1], ocsp.OCSPCertStatus.GOOD, signer=other_ca)
response("delegated.der", ca, client[1], ocsp.OCSPCertStatus.GOOD, signer=responder)
response("bad-responder.der", ca, client[1], ocsp.OCSPCertStatus.GOOD, signer=second)
response("wrong-client.der", ca, second[1], ocsp.OCSPCertStatus.GOOD)
(root / "server-chain.pem").write_bytes(server_a[1].public_bytes(pem) + ca[1].public_bytes(pem))
(root / "multi-ca.pem").write_bytes(ca[1].public_bytes(pem) + other_ca[1].public_bytes(pem))
(root / "fingerprints.json").write_text(json.dumps(fingerprints), encoding="utf-8")
print(f"Created isolated TLS test fixtures in {root}")
