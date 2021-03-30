#!/bin/sh

export GOELEVEN_INTERFACE=127.0.0.1:8080
export GOELEVEN_ALLOWEDIP=127.0.0.1
export GOELEVEN_MAXSESSIONS=1
export GOELEVEN_HSMLIB=/usr/lib/softhsm/libsofthsm2.so
export SOFTHSM_CONF=/etc/softhsm/softhsm2.conf
# See https://golang.org/doc/go1.6#cgo
export GODEBUG=cgocheck=0

# expected to be externally configured
: ${GOELEVEN_SECRET:=changemeplease}
: ${GOELEVEN_LABEL:=docker1}
: ${GOELEVEN_KEY_BITS:=3072}

# really internal config, but could be set by advanced users
: ${SOFTHSM2_CONF:=/opt/goeleven/softhsm2.conf}
: ${GOELEVEN_SLOT_PASSWORD:=${GOELEVEN_SECRET}}
: ${GOELEVEN_KEY_LABEL:=${GOELEVEN_LABEL}:${GOELEVEN_SECRET}}
: ${GOELEVEN_STATUS_KEY:=${GOELEVEN_LABEL}}

export GOELEVEN_LABEL GOELEVEN_KEY_BITS SOFTHSM2_CONF GOELEVEN_SLOT_PASSWORD GOELEVEN_KEY_LABEL GOELEVEN_STATUS_KEY

if [ -e "${SOFTHSM2_CONF}" ] ; then
    TOKENDIR=$(awk -F '[[:space:]]*=[[:space:]]*' '/directories.tokendir/ {print $2}' "${SOFTHSM2_CONF}")
    echo "Getting token directory from ${SOFTHSM2_CONF}: ${TOKENDIR}"
    : ${TOKENDIR:=/softhsm/tokens/}
    mkdir -p "${TOKENDIR}"
    chown -R root:softhsm "${TOKENDIR}"
    chmod 2770 "${TOKENDIR}" $(dirname "${TOKENDIR%%/}")
else
    echo "ERROR: Unknown softhsm2 config"
    exit 1;
fi

INITIALISED=$(softhsm2-util --show-slots | awk "/Label:.*${GOELEVEN_LABEL}/ { print \$2 }")
if [ "${INITIALISED}" != "${GOELEVEN_LABEL}" ] ; then
    echo "Initialise a new HSM and generate a key"
    softhsm2-util --init-token --free --label "${GOELEVEN_LABEL}" --pin "${GOELEVEN_SLOT_PASSWORD}" --so-pin "${GOELEVEN_SLOT_PASSWORD}"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --id 01 --login --pin "${GOELEVEN_SLOT_PASSWORD}" --keypairgen --key-type rsa:${GOELEVEN_KEY_BITS} --usage-sign
    #pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --login --pin "${GOELEVEN_SLOT_PASSWORD}"
fi

export GOELEVEN_SLOT=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/^Slot / { print $2; exit }')
export GOELEVEN_SERIALNUMBER=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/Serial number:/ { print $3; exit }')
export ARCH=$(uname -m)

envsubst < /opt/goeleven/openssl.cnf.tmpl > /opt/goeleven/openssl.cnf
export OPENSSL_CONF=/opt/goeleven/openssl.cnf

# create the cert if it doesn't exit
if [ \! -e "/opt/goeleven/${GOELEVEN_LABEL}.der" ] ; then
    echo "Generate a new certifictate"
    openssl req -new -x509 -engine pkcs11 -keyform engine -key "${GOELEVEN_SLOT}:01" -passin env:GOELEVEN_SLOT_PASSWORD -days 5479 -sha256 -subj "/C=ZA/CN=${GOELEVEN_LABEL}" -outform der -out "/opt/goeleven/${GOELEVEN_LABEL}.der"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --id 01 --login --pin "${GOELEVEN_SLOT_PASSWORD}" --type cert -w "${GOELEVEN_LABEL}.der"
fi

# export the cert into a useful form
if [ \! -e "/softhsm/${GOELEVEN_LABEL}.crt" ] ; then
    echo "Export certificate to /softhsm/${GOELEVEN_LABEL}.crt"
    pkcs11-tool ${GOELEVEN_HSMLIB} --write-object 01 --type cert --output-file "/opt/goeleven/${GOELEVEN_LABEL}.der"
    openssl x509 -in "/opt/goeleven/${GOELEVEN_LABEL}.der" -inform der -outform pem -out "/softhsm/${GOELEVEN_LABEL}.crt"
    openssl x509 -in "/softhsm/${GOELEVEN_LABEL}.crt" -text
fi

cd /opt/goeleven
exec /opt/goeleven/goeleven
