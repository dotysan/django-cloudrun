#! /usr/bin/env bash
#
# Deploy Django to Google Cloud Run in one click.
#  - following along with https://codelabs.developers.google.com/codelabs/cloud-run-django
#  - this is only tested in Google Cloud Shell (note calls to curl metadata)
#
set -ex

name=gcr-test5

main() {
    venv

    initgit
    initpip
    initdj

    #deactivate # don't need venv anymore; from here on, it's all docker baby, yeah...
    #rm -fr .venv/

    # inside Cloud Shell, this forces authentication and sets core/account
    gcloud config list

    # TODO: initproj() i.e. don't assume the project already exists?
    #initsvc gcr-test-svcacct
    #initdb gcr-test2
    initsvc "$name-svcacct"
    initdb "$name"

    lynx -dump -width=1024 https://codelabs.developers.google.com/codelabs/cloud-run-django >cloud-run-django.txt
    initapp
    initbuild
    rm cloud-run-django.txt

    #API: gcloud builds requires cloudbuild.googleapis.com
# also, getting the following herrror without Build API enabled
#+ gcloud secrets add-iam-policy-binding application_settings --member serviceAccount:340260235294@cloudbuild.gserviceaccount.com --role roles/secretmanager.secretAccessor
#ERROR: Policy modification failed. For a binding with condition, run "gcloud alpha iam policies lint-condition" to identify issues in condition.
#ERROR: (gcloud.secrets.add-iam-policy-binding) INVALID_ARGUMENT: Service account 340260235294@cloudbuild.gserviceaccount.com does not exist.

    image="gcr.io/$projid/$name-image"

    # build app image using Buildpack
    gcloud builds submit --pack image="$image"

    # run migration
    #gcloud builds submit --config migrate.yaml
    gcloud builds submit --config migrate.yaml --substitutions \
      "_REGION=$region,_IMAGE_NAME=$image,_INSTANCE_CONNECTION_NAME=$projid:$region:$name-dbinstance"
#+ gcloud builds submit --config migrate.yaml --substitutions _REGION=us-west1,_IMAGE_NAME=gcr.io/gcr-test1-deleteme/gcr-test5-image,_INSTANCE_CONNECTION_NAME=gcr-test1-deleteme:us-west1:gcr-test5-dbinstance
#Creating temporary tarball archive of 7535 file(s) totalling 73.9 MiB before compression.
#Uploading tarball of [.] to [gs://gcr-test1-deleteme_cloudbuild/source/1652658091.269284-7ca9253e95bc4e919693ac430ec5c2a1.tgz]
#ERROR: (gcloud.builds.submit) INVALID_ARGUMENT: generic::invalid_argument: key "_REGION" in the substitution data is not matched in the template
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

initgit() {
    if [ ! -d .git ]
    then
        git init
        echo -e '\n# ignore Python virtual environment\n.venv/' >>.gitignore
        git add .
        git commit -m 'initial commit'
    fi
}

initpip() {
    if [ ! -f requirements.txt ]
    then
        pip install Django
        #pip install django-environ django-storages[google] gunicorn psycopg2
        pip freeze |tee requirements.txt
        git add .
        git commit -m 'pull pip requirements for Django, Google Cloud, & Postgres'
    fi
}

initdj() {
    if [ ! -d cloudrun ]
    then
        django-admin startproject cloudrun .
        git add .
        git commit -m 'django-admin startproject cloudrun .'
    fi
}

initsvc() {
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

    #API: gcloud sql instances requires sqladmin.googleapis.com

    local exists=$(gcloud sql instances list --filter "$dbname-dbinstance")
    if [ "$exists" ]
    then return # TODO: make sure everything below gets done
    #then gcloud sql instances delete "$dbname-instance"
    fi

    gcloud sql instances create "$dbname-dbinstance" \
      --project "$projid" --database-version POSTGRES_14 \
      --tier db-f1-micro --region "$region" --async
      #? --activation-policy=on-demand
    local pending=$(gcloud sql operations list --instance="$dbname-dbinstance" --filter='status!=DONE' --format='value(name)') #'
    if [ "$pending" ]
    then gcloud sql operations wait --timeout=unlimited "$pending"
    fi
    #gcloud sql instances describe "$dbname-instance"

    gcloud sql databases create "$dbname-db" --instance "$dbname-dbinstance"
    local djpass=$(mkapass)
    echo "localhost:5432:$dbname-db:djuser:$djpass" >>~/.pgpass
    chmod 0600 ~/.pgpass
    gcloud sql users create djuser --instance "$dbname-dbinstance" --password "$djpass"

    # grant the service account permission to connect to the instance
    gcloud projects add-iam-policy-binding "$projid" \
      --member "serviceAccount:$svcemail" --role roles/cloudsql.client

    # create the storage bucket
    #echo gsutil mb -l "$region" "gs://$projid-media"
    if ! gsutil ls -b "gs://$projid-media"
    then gsutil mb -l "$region" -p "$projid" "gs://$projid-media"
    fi

    # save secrets
    cat >.env <<-EOF
	DATABASE_URL="postgres://djuser:$djpass@//cloudsql/$projid:$region:$dbname-dbinstance/$dbname-db"
	GS_BUCKET_NAME="gs://$projid-media"
	SECRET_KEY="$(mkapass 50)"
	DEBUG="True"
	EOF
    #API: gcloud secrets requires secretmanager.googleapis.com
    gcloud secrets create "$name-appsettings" --data-file .env
    rm .env
    gcloud secrets add-iam-policy-binding "$name-appsettings" \
      --member "serviceAccount:$svcemail" --role roles/secretmanager.secretAccessor
    #gcloud secrets versions list "$name-appsettings"
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

initapp() {
    if [ ! -f cloudrun/basesettings.py ]
    then
        sed -n '/^import io$/,/^GS_DEFAULT_ACL = "publicRead"/p' cloud-run-django.txt >newsettings.py
        mv cloudrun/settings.py cloudrun/basesettings.py
        mv newsettings.py cloudrun/settings.py
        git add cloudrun
        git commit -m 'customize settings for using environment'
    fi
    if [ ! -f Procfile ]
    then # TODO? customize workers by number of cores in instance?
        echo 'web: gunicorn --bind 0.0.0.0:$PORT --workers 1 --threads 8 --timeout 0 cloudrun.wsgi:application' >Procfile
        git add Procfile
        git commit -m 'using Cloud Native Buildpacks instead of Docker'
    fi
}

initbuild() {

#    if [ ! -e cloudrun/migrations/0001_createsuperuser.py ]
#    then
#        mkdir cloudrun/migrations
#        touch cloudrun/migrations/__init__py
#        sed -n '
#          /^myproject\/migrations\/0001_createsuperuser\.py$/,/^   Now back in the terminal/p
#        ' cloud-run-django.txt |sed '1,2d;$d' |sed '$d' >cloudrun/migrations/0001_create_superuser.py
#        git add cloudrun
#        git commit -m 'first Django migration creates superuser'
#    fi
#
    if [ ! -e migrate.yaml ]
    then
        sed -n '/^steps:$/,/^  dynamicSubstitutions:/p' cloud-run-django.txt >migrate.yaml
        # TODO: fix variables and substiutions
#        git add migrate.yaml
#        git commit -m 'YAML for Cloud Build'
    fi

    local projnum=$(getprojnum "$projid")
    local msa="serviceAccount:$projnum@cloudbuild.gserviceaccount.com"

    # allow Cloud Build access to Secret Manager
    gcloud secrets add-iam-policy-binding "$name-appsettings" \
      --member "$msa" --role roles/secretmanager.secretAccessor

    # also allow Cloud Build to perform Django DB migrations
    gcloud projects add-iam-policy-binding "$projid" \
      --member "$msa" --role roles/cloudsql.client

    # admin password?
    local oldpass=$(gcloud secrets describe admin_password)
    if [ -z "$oldpass" ]
    then
        local admin_password="$(mkapass)"
        echo -n "${admin_password}" |gcloud secrets create admin_password --data-file=-
    fi
    gcloud secrets add-iam-policy-binding admin_password \
      --member "$msa" --role roles/secretmanager.secretAccessor
}

getprojnum() {
    local projid="$1"
    gcloud projects describe "$projid" --format 'value(projectNumber)'
}

main
exit 0
