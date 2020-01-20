gem build ./logstash-input-mongodb.gemspec
pushd .
cd ..
logstash-plugin install ./logstash-input-mongodb/logstash-input-mongodb-0.1.0.gem
popd
