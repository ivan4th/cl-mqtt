#!/bin/bash
set -u -e
commit_id=17afdf7fb8e148f376d63592bbf3dd4ccdf19e84
cd "$(dirname $0)"
rm -rf interop/
mkdir interop
cd interop
git clone git://git.eclipse.org/gitroot/paho/org.eclipse.paho.mqtt.testing.git
git checkout "$commit_id"
