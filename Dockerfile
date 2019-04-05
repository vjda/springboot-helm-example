FROM openjdk:8-jre-alpine

ENV JAVA_VERSION 1.8
ENV JAVA_OPTS_EXT "-Xms256m -Xmx512m"
ENV JAVA_HEAP ""
ENV JAVA_PARAMETERS ""
ENV APP_DIR /opt/deployments
ENV APP_NAME app.jar
ENV APP_PORT 8080

RUN addgroup java && \
    adduser -D -G java java && \
    mkdir -p ${APP_DIR} && \
    chown java:java ${APP_DIR}

WORKDIR ${APP_DIR}

COPY start.sh .

RUN chmod 755 start.sh

USER java

COPY build/libs/*.jar app.jar

EXPOSE 8080

ENTRYPOINT ["sh", "./start.sh"]
