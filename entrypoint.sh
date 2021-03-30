#!/bin/sh

export GOELEVEN_INTERFACE=0.0.0.0:8080
export GOELEVEN_MAXSESSIONS=1
# See https://golang.org/doc/go1.6#cgo
export GODEBUG=cgocheck=0

# expected to be externally configured
: ${GOELEVEN_SECRET:=changemeplease}
: ${GOELEVEN_LABEL:=docker1}
: ${GOELEVEN_KEY_BITS:=3072}
: ${GOELEVEN_CCTLD:=ZA}

# really internal config, but could be set by advanced users
: ${SOFTHSM2_CONF:=/opt/goeleven/softhsm2.conf}
: ${GOELEVEN_HSMLIB:=/usr/lib/softhsm/libsofthsm2.so}
: ${GOELEVEN_SLOT_PASSWORD:=${GOELEVEN_SECRET}}
: ${GOELEVEN_KEY_LABEL:=${GOELEVEN_LABEL}:${GOELEVEN_SECRET}}
: ${GOELEVEN_STATUS_KEY:=${GOELEVEN_LABEL}}
: ${GOELEVEN_ALLOWEDIP:=172.17.0.1}

export GOELEVEN_LABEL GOELEVEN_KEY_BITS SOFTHSM2_CONF GOELEVEN_HSMLIB GOELEVEN_SLOT_PASSWORD GOELEVEN_KEY_LABEL GOELEVEN_STATUS_KEY GOELEVEN_ALLOWEDIP

if [ -e "${SOFTHSM2_CONF}" ] ; then
    echo "## Getting token directory from ${SOFTHSM2_CONF}: ${TOKENDIR}"
    TOKENDIR=$(awk -F '=' '/directories.tokendir/ {print $2}' "${SOFTHSM2_CONF}" | sed -E 's/^[[:space:]]*//g; s/[[:space:]]*$//g')
    if [ -n "${TOKENDIR}" -a \! -e "${TOKENDIR%%/}" ] ; then
        echo "## Prepping token directory at ${TOKENDIR}"
        mkdir -p "${TOKENDIR}"
        chown -R root:softhsm "${TOKENDIR}"
        chmod 2770 "${TOKENDIR}" $(dirname "${TOKENDIR%%/}")
    fi
else
    echo "## ERROR: SOFTHSM2_CONF could not be found!"
    exit 1;
fi

INITIALISED=$(softhsm2-util --show-slots | awk "/Label:.*${GOELEVEN_LABEL}/ { print \$2 }")
if [ "${INITIALISED}" != "${GOELEVEN_LABEL}" ] ; then
    echo "## Initialise a new HSM and generate a new RSA key"
    softhsm2-util --init-token --free --label "${GOELEVEN_LABEL}" --pin "${GOELEVEN_SLOT_PASSWORD}" --so-pin "${GOELEVEN_SLOT_PASSWORD}"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --id 01 --login --pin "${GOELEVEN_SLOT_PASSWORD}" --keypairgen --key-type rsa:${GOELEVEN_KEY_BITS} --usage-sign
fi

export GOELEVEN_SLOT=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/^Slot / { print $2; exit }')
export GOELEVEN_SERIALNUMBER=$(softhsm2-util --show-slots --label "${GOELEVEN_LABEL}" | awk '/Serial number:/ { print $3; exit }')
export ARCH=$(uname -m)

echo "## Token ${GOELEVEN_SERIALNUMBER} found in slot ${GOELEVEN_SLOT}"

envsubst < /opt/goeleven/openssl.cnf.tmpl > /opt/goeleven/openssl.cnf
export OPENSSL_CONF=/opt/goeleven/openssl.cnf

# create the cert if it doesn't exit
if [ \! -e "/opt/goeleven/${GOELEVEN_LABEL}.der" ] ; then
    echo "## Generate a new certifictate"
    openssl req -new -x509 -engine pkcs11 -keyform engine -key "${GOELEVEN_SLOT}:01" -passin env:GOELEVEN_SLOT_PASSWORD -days 5479 -sha256 -subj "/C=${GOELEVEN_CCTLD}/CN=${GOELEVEN_LABEL}" -outform der -out "/opt/goeleven/${GOELEVEN_LABEL}.der"
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --id 01 --login --pin "${GOELEVEN_SLOT_PASSWORD}" --type cert -w "${GOELEVEN_LABEL}.der"
fi

# export the cert into a useful form
if [ \! -e "/softhsm/${GOELEVEN_LABEL}.crt" ] ; then
    echo "## Export certificate to /softhsm/${GOELEVEN_LABEL}.crt"
    # always get the cert token from the HSM
    pkcs11-tool --module ${GOELEVEN_HSMLIB} --label "${GOELEVEN_LABEL}" --type cert --read-object --output-file "/opt/goeleven/${GOELEVEN_LABEL}.der"
    openssl x509 -in "/opt/goeleven/${GOELEVEN_LABEL}.der" -inform der -outform pem -out "/softhsm/${GOELEVEN_LABEL}.crt"
    openssl x509 -in "/softhsm/${GOELEVEN_LABEL}.crt" -text
    echo
fi

echo "## Executing goeleven"
cd /opt/goeleven
exec /opt/goeleven/goeleven
