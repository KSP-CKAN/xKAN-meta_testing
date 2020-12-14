FROM kspckan/metadata
ADD . /workdir
WORKDIR /workdir
RUN pip3 install .
WORKDIR /
RUN rm -r /workdir
ENTRYPOINT ["ckanmetatester"]
