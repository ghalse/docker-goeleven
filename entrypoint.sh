#!/bin/sh

export GOELEVEN_INTERFACE=127.0.0.1:8080
export GOELEVEN_ALLOWEDIP=127.0.0.1
export GOELEVEN_MAXSESSIONS=1
export GOELEVEN_HSMLIB=/usr/lib/softhsm/libsofthsm2.so
export SOFTHSM_CONF=/etc/softhsm/softhsm2.conf
# See https://golang.org/doc/go1.6#cgo
GODEBUG=cgocheck=0

: ${GOELEVEN_SECRET:=changemeplease}
: ${GOELEVEN_LABEL:=docker1}

: ${GOELEVEN_SLOT_PASSWORD:=${GOELEVEN_SECRET}}
: ${GOELEVEN_KEY_LABEL:=${GOELEVEN_LABEL}:${GOELEVEN_SECRET}}
: ${GOELEVEN_STATUS_KEY:=${GOELEVEN_LABEL}}

export GOELEVEN_SLOT_PASSWORD GOELEVEN_KEY_LABEL GOELEVEN_STATUS_KEY

INITIALISED=$(softhsm2-util --show-slots | awk "/Label:.*${GOELEVEN_LABEL}/ { print \$2 }")

if [ "${INITIALISED}" != "${GOELEVEN_LABEL}" ] ; then
    echo "Initialise a new HSM and generate a key"
    softhsm2-util --init-token --free --label "${GOELEVEN_LABEL}" --pin "${GOELEVEN_SLOT_PASSWORD}" --so-pin "${GOELEVEN_SLOT_PASSWORD}"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --login --pin "${GOELEVEN_SLOT_PASSWORD}" --keypairgen --key-type rsa:3072 --usage-sign
    #pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --login --pin "${GOELEVEN_SLOT_PASSWORD}"
    
fi

export GOELEVEN_SLOT=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/^Slot / { print $2; exit }')
export GOELEVEN_SERIALNUMBER=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/Serial number:/ { print $3; exit }')

cd /opt/goeleven
exec /opt/goeleven/goeleven
