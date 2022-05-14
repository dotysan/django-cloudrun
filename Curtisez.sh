#! /usr/bin/env bash
#
# Deploy Django to Google Cloud Run in one click.
#  - following along with https://codelabs.developers.google.com/codelabs/cloud-run-django
#
set -ex

main() {
    venv

    initpip

    if [ ! -d cloudrun ]
    then
        django-admin startproject cloudrun .
        git commit -m 'django-admin startproject cloudrun .'
    fi

    deactivate # don't need venv anymore; from here on, it's all docker baby, yeah...

    initrun gcr-test-svcacct
}

venv() {
    if [ -d .venv ]
    then
        source .venv/bin/activate
        return
    fi
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip setuptools wheel
}

initpip() {

    if [ ! -d .git ]
    then
        git init
        echo '.venv/' >.gitignore
    fi

    if [ ! -f requirements.txt ]
    then
        pip install Django
        pip freeze >requirements.txt

        git add .
        git commit -m 'initial commit'
    fi
}

initrun() {
    local svcacct="$1"

    projid=$(gcloud config get-value core/project)
    local shellzone=$(curl metadata/computeMetadata/v1/instance/zone)
    zone="${shellzone##*/}"
    region="${zone%-*}"

    svcemail=$(gcloud iam service-accounts list --filter "$svcacct" --format 'value(email)') #'
    if [ -z "$svcemail" ]
    then
        gcloud iam service-accounts create "$svcacct"
        svcemail=$(gcloud iam service-accounts list --filter "$svcacct" --format 'value(email)') #'
    fi
}

main
exit 0
