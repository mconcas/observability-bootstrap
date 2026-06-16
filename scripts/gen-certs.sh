#!/usr/bin/env bash
# Generate the transport-layer TLS PKI that the OpenSearch security plugin
# requires: a root CA, a node certificate, and an admin certificate.
#
# Run this ONCE before the first `docker compose up`. Output lands in
# opensearch/certs/ (gitignored). Re-running regenerates everything; for a
# single-node cluster that is harmless, but you must then recreate the
# opensearch container so it picks up the new node cert.
#
# The certificate subjects must match plugins.security.nodes_dn /
# authcz.admin_dn in opensearch/opensearch.yml.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/opensearch/certs"
DAYS=3650

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo "==> Root CA"
openssl genrsa -out root-ca-key.pem 2048
openssl req -new -x509 -sha256 -days "$DAYS" -key root-ca-key.pem \
  -subj "/CN=observability-bootstrap-ca" -out root-ca.pem

# gen_cert <name> <CN> <extendedKeyUsage>
gen_cert() {
  local name="$1" cn="$2" eku="$3"
  echo "==> Certificate: CN=$cn ($name)"
  openssl genrsa -out "${name}-key-temp.pem" 2048
  # OpenSearch requires PKCS#8 keys.
  openssl pkcs8 -inform PEM -outform PEM -topk8 -nocrypt \
    -in "${name}-key-temp.pem" -out "${name}-key.pem"
  rm -f "${name}-key-temp.pem"
  openssl req -new -key "${name}-key.pem" -subj "/CN=${cn}" -out "${name}.csr"
  printf 'extendedKeyUsage=%s\n' "$eku" > "${name}.ext"
  openssl x509 -req -in "${name}.csr" -CA root-ca.pem -CAkey root-ca-key.pem \
    -CAcreateserial -sha256 -days "$DAYS" -extfile "${name}.ext" -out "${name}.pem"
  rm -f "${name}.csr" "${name}.ext"
}

# Node cert needs both server and client auth (nodes talk to each other both
# ways); admin cert is a client of the transport layer.
gen_cert esnode opensearch-node1 "serverAuth,clientAuth"
gen_cert admin  admin            "clientAuth"

rm -f root-ca.srl
# The opensearch container runs as uid 1000; key files stay readable by it.
chmod 600 ./*-key.pem
chmod 644 root-ca.pem esnode.pem admin.pem

echo "==> Done. Certs in $CERT_DIR"
