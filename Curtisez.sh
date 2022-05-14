#! /usr/bin/env bash
#
#
set -ex

main() {
    venv

    #initpip

    django-admin startproject cloudrun .
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
    git init
    echo '.venv/' >.gitignore
    pip install Django
    pip freeze >requirements.txt
}

main
exit 0
