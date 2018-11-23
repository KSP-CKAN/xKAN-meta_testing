FROM jenkins/ssh-slave

USER root

RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF
ADD mono-official.list /etc/apt/sources.list.d/
RUN apt-get update && apt-get install -y mono-complete jq python-demjson libjson-any-perl libtest-most-perl libipc-system-simple-perl libwww-mechanize-perl libperl-version-perl python-jsonschema jsonlint
ADD .ssh /home/jenkins/.ssh
