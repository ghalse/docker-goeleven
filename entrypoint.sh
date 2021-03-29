#!/bin/sh

export GOELEVEN_INTERFACE=127.0.0.1:8080
export GOELEVEN_ALLOWEDIP=127.0.0.1
export GOELEVEN_MAXSESSIONS=1
export GOELEVEN_HSMLIB=/usr/lib/softhsm/libsofthsm2.so
export SOFTHSM_CONF=/etc/softhsm/softhsm2.conf
# See https://golang.org/doc/go1.6#cgo
export GODEBUG=cgocheck=0

: ${GOELEVEN_SECRET:=changemeplease}
: ${GOELEVEN_LABEL:=docker1}
: ${GOELEVEN_KEY_BITS:=3072}

: ${GOELEVEN_SLOT_PASSWORD:=${GOELEVEN_SECRET}}
: ${GOELEVEN_KEY_LABEL:=${GOELEVEN_LABEL}:${GOELEVEN_SECRET}}
: ${GOELEVEN_STATUS_KEY:=${GOELEVEN_LABEL}}

export GOELEVEN_SLOT_PASSWORD GOELEVEN_KEY_LABEL GOELEVEN_STATUS_KEY

INITIALISED=$(softhsm2-util --show-slots | awk "/Label:.*${GOELEVEN_LABEL}/ { print \$2 }")

if [ "${INITIALISED}" != "${GOELEVEN_LABEL}" ] ; then
    echo "Initialise a new HSM and generate a key"
    softhsm2-util --init-token --free --label "${GOELEVEN_LABEL}" --pin "${GOELEVEN_SLOT_PASSWORD}" --so-pin "${GOELEVEN_SLOT_PASSWORD}"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --id 01 --login --pin "${GOELEVEN_SLOT_PASSWORD}" --keypairgen --key-type rsa:${GOELEVEN_KEY_BITS} --usage-sign
    #pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --login --pin "${GOELEVEN_SLOT_PASSWORD}"
fi

export GOELEVEN_SLOT=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/^Slot / { print $2; exit }')
export GOELEVEN_SERIALNUMBER=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/Serial number:/ { print $3; exit }')

cat <<- EOM > /opt/goeleven/openssl.cfg
openssl_conf = openssl_init

[openssl_init]
engines = engine_section

[ req ]
default_bits = ${GOELEVEN_KEY_BITS}
default_md = sha256
string_mask = utf8only
x509_extensions = v3_ca
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
countryName = ZA
commonName = ${GOELEVEN_LABEL}

[ v3_ca ]
subjectKeyIdentifier=hash
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
authorityKeyIdentifier=keyid:always,issuer
issuerAltName=issuer:copy
basicConstraints = critical,CA:false

[engine_section]
pkcs11 = pkcs11_section

[pkcs11_section]
dynamic_path = /usr/lib/$(uname -m)-linux-gnu/engines-1.1/pkcs11.so
MODULE_PATH = ${GOELEVEN_HSMLIB}
init = ${GOELEVEN_SLOT}
EOM
export OPENSSL_CONF=/opt/goeleven/openssl.cfg

if [ \! -e "/opt/goeleven/${GOELEVEN_LABEL}.der" ] ; then
    echo "Generate a new certifictate"
    openssl req -new -x509 -engine pkcs11 -keyform engine -key "${GOELEVEN_SLOT}:01" -passin env:GOELEVEN_SLOT_PASSWORD -days 5479 -sha256 -subj "/C=ZA/CN=${GOELEVEN_LABEL}" -outform der -out "/opt/goeleven/${GOELEVEN_LABEL}.der"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --id 01 --login --pin "${GOELEVEN_SLOT_PASSWORD}" -y cert -w "${GOELEVEN_LABEL}.der"
fi
openssl x509 -in "/opt/goeleven/${GOELEVEN_LABEL}.der" -inform der -outform pem -out "/opt/goeleven/${GOELEVEN_LABEL}.crt"
openssl x509 -in "/opt/goeleven/${GOELEVEN_LABEL}.crt" -text

cd /opt/goeleven
exec /opt/goeleven/goeleven
