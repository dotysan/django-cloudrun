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
    initdb gcr-test2
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

initdb() {
    dbname="$1"

    # gcloud sql instances requires sqladmin.googleapis.com

    local exists=$(gcloud sql instances list --filter "$dbname-instance")
    if [ "$exists" ]
    then return
    #then echo gcloud sql instances delete "$dbname-instance"
    fi

    gcloud sql instances create "$dbname-instance" \
      --project "$projid" --database-version POSTGRES_14 \
      --tier db-f1-micro --region "$region" --async
      #? --activation-policy=on-demand
    local pending=$(gcloud sql operations list --instance="$dbname-instance" --filter='status!=DONE' --format='value(name)') #'
    if [ "$pending" ]
    then gcloud sql operations wait --timeout=unlimited "$pending"
    fi
    #gcloud sql instances describe "$dbname-instance"

    gcloud sql databases create "$dbname-db" --instance $dbname-instance
    local djpass=$(mkapass)
    echo "localhost:5432:$dbname-db:djuser:$djpass" >>~/.pgpass
    chmod 0600 ~/.pgpass
    gcloud sql users create djuser --instance "$dbname-instance" --password "$djpass"

    # grant the service account permission to connect to the instance
    gcloud projects add-iam-policy-binding "$projid" \
      --member "serviceAccount:$svcemail" --role roles/cloudsql.client

    # create the storage bucket
    #echo gsutil mb -l "$region" "gs://$projid-media"
    gsutil mb -l "$region" -p "$projid" "gs://$projid-media"

    # save secrets
    cat >.env <<-EOF
	DATABASE_URL="postgres://djuser:$djpass@//cloudsql/$projid:$region:$dbname-instance/$dbname-db"
	GS_BUCKET_NAME="gs://$projid-media"
	SECRET_KEY="$(mkapass 50)"
	DEBUG="True"
	EOF
    # gcloud secrets requires secretmanager.googleapis.com
    gcloud secrets create application_settings --data-file .env
    rm .env
    gcloud secrets add-iam-policy-binding application_settings \
      --member "serviceAccount:$svcemail" --role roles/secretmanager.secretAccessor
    gcloud secrets versions list application_settings
}

mkapass() {
    local passlen="${1:-20}"
    #local charlist="\`1234567890-=~!@#\$%^&*()_+qwertyuiop[]\asdfghjkl;'zxcvbnm,./QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>?"
    #local charlist="\`1234567890-=~!#\$%^&*()_+qwertyuiop[]asdfghjkl;'zxcvbnm,.QWERTYUIOP{}|ASDFGHJKL\"ZXCVBNM<>?"
    local charlist="1234567890-=~!#%^&*()_+qwertyuiop[]asdfghjkl;zxcvbnm,.QWERTYUIOP{}|ASDFGHJKLZXCVBNM<>?"
    local charlen=${#charlist}
    for ((i=1; i<=$passlen; i++))
    do pass+="${charlist:$[SRANDOM%charlen]:1}"
    done
    echo "$pass"
}

main
exit 0
