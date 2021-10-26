FROM cyanogilvie/m2:v0.9.19-stripped
WORKDIR /testscripts
RUN apk --update --no-cache add make iproute2
ENTRYPOINT ["/usr/bin/make"]
CMD ["test"]
