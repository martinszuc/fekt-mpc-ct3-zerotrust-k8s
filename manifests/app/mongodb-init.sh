#!/bin/sh
# replaces the image's script.sh: its ratings_data.json is not valid JSON for current mongoimport
set -e
mongosh --quiet test --eval 'db.ratings.drop(); db.ratings.insertMany([{rating: 5}, {rating: 4}])'
