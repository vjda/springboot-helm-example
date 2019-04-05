# Spring boot helm example

Este proyecto es una _prueba de concepto_ para mostrar cómo inyectar la configuración de una aplicación Spring y el manejo de secrets en función de distintos entornos.

## Motivación

En arquitecturas de microservicios, un problema común es la gestión de la configuración de cada microservicio desplegado. Existen varias estrategias distintas, cada una con sus pros y contras. En este proyecto, vamos a ver un ejemplo de artefacto que contiene a su vez, un artefacto _desplegable_ (imagen docker), la configuración de la propia aplicación, componentes de los que depende (si los hubiese) y recursos de infraestructura necesarios para que pueda ejecutarse correctamente.

## Requisitos

Es necesario disponer de un clúster en Kubernetes o derivados (por ejemplo, Openshift) para desplegar el servicio y la infraestructura. Para pruebas desde local puede usarse [Minikube](https://kubernetes.io/docs/setup/minikube/).

Además, será necesario descargarse el binario de Helm e instalar el tiller dentro del propio clúster. Consulte el [repositorio oficial de Helm](https://github.com/helm/helm) para más información.

## Componentes

El proyecto consta principalmente de 3 componentes:

* Código fuente de un servicio muy simple con Spring Boot que expone varios endpoints de Spring Actuator:
  * `/actuator/info`: información de la aplicación.
  * `/actuator/health`: información del estado de salud de los componentes de los que dependende la aplicación.
  * `/actuator/configprops`: Muestra una lista de todos `@ConfigurationProperties`.
  * `/actuator/env`: Expone las propiedades de `ConfigurableEnvironment` de Spring.

  > Para más información consulte la [documentación oficial de Spring Actuator](https://docs.spring.io/spring-boot/docs/current/reference/html/production-ready-endpoints.html).

* Ficheros para la construcción de una imagen docker que contiene el artefacto jar del servicio.
  * `Dockerfile`: contiene las instrucciones para construcir la imagen docker.
  * `start.sh`: script que inicia el servicio al arrancar el contenedor docker.

* Chart de helm con las plantillas y valores por defecto para desplegar el servicio en un clúster de Kubernetes.

## Chart de Helm

Helm usa un formato de empaquetado llamado chart. Una chart es una colección de archivos que describen un conjunto relacionado de recursos de Kubernetes. Se podría utilizar una sola chart para implementar algo simple, como un pod de caché, o algo complejo, como un stack completo de web apps con servidores HTTP, bases de datos, cachés, etc.

Las charts se crean como archivos dispuestos en un árbol de directorios, que pueden ser empaquetados en artefactos versionados para ser desplegados más tarde.

### Estructura de una chart

Tal y como se explica en la [documentación de Helm](https://helm.sh/docs/developing_charts/#the-chart-file-structure) la estructura básica de cualquier chart consta de lo siguiente:

```text
wordpress/
  Chart.yaml          # A YAML file containing information about the chart
  LICENSE             # OPTIONAL: A plain text file containing the license for the chart
  README.md           # OPTIONAL: A human-readable README file
  requirements.yaml   # OPTIONAL: A YAML file listing dependencies for the chart
  values.yaml         # The default configuration values for this chart
  charts/             # A directory containing any charts upon which this chart depends.
  templates/          # A directory of templates that, when combined with values,
                      # will generate valid Kubernetes manifest files.
  templates/NOTES.txt # OPTIONAL: A plain text file containing short usage notes
```

Además, bajo la carpeta `chart` de este proyecto encontraremos la carpeta `resources` con los ficheros de configuración necesarios de la aplicación y el fichero `values-production.yaml` que contiene los valores que sobrescriben a los valores por defecto de `values.yaml` y están enfocados a desplegar la aplicación en el clúster de producción.

> Es importante recalcar que aunque el `values-production.yaml` podría estar en el mismo repositorio que la chart, conviene separarlo, por razones de seguridad, a un repositorio distinto el cual solo tenga acceso el equipo encargado del despliegue en producción. De este modo se evita compartir la configuración sensible (secrets) con los demás equipos.

### Inyección de la configuración

Para este ejemplo, se ha hecho que el servicio en Spring dependa de una caché de redis y una base de datos MongoDB. La configuración de la aplicación se encuentra bajo [chart/resources/application.yml](/chart/resources/application.yml). Se ha parametrizado la configuración que es dinámica entre los diferentes entornos. En concreto las siguientes propiedades:

```yaml
spring:
  data:
    mongodb:
      uri: ${MONGODB_CONNECTION_URL:mongodb://localhost/test}
  redis:
    url: ${REDIS_CONNECTION_URL:redis://localhost:6379}
```

La url de acceso a la base de datos MongoDB se carga desde una variable de entorno `MONGODB_CONNECTION_URL` o en caso de no existir, por defecto, asume `mongodb://localhost/test`. La misma estrategia se sigue para la conexión con redis; se lee desde la variable `REDIS_CONNECTION_URL` o se asume `redis://localhost:6379` por defecto.

Estas dos variables al contener información de caracter sensible (datos de conexión a máquinas), se leerán desde dos secrets (por defecto `redis-secret` y `mongodb-secret`) y se inyectarán como variables de entorno en el arranque del pod. La configuración necesaria para hacer esto se encuentra en [chart/values.yaml](chart/values.yaml).

```yaml
# Se declaran los dos secrets necesarios
secrets:
  redis:
    name: redis-secret
    data:
      connection-url: "redis://:myRedisPass@poc-redis-master:6379"
  mongodb:
    name: mongodb-secret
    data:
      connection-url: "mongodb://mongouser:myM0ng0Pass@poc-mongodb:27017/my-database"

extraEnv: |
# Pasa como argumento la ruta del fichero de configuración de la aplicación
  - name: JAVA_PARAMETERS
    value: --spring.config.location=file:///opt/deployments/config/application.yml
  
# Se inyectan como variables de entorno con los datos de los secrets anteriores
  - name: REDIS_CONNECTION_URL
    valueFrom:
      secretKeyRef:
        name: redis-secret
        key: connection-url
  - name: MONGODB_CONNECTION_URL
    valueFrom:
      secretKeyRef:
        name: mongodb-secret
        key: connection-url

# Monta en la ruta especifica el configmap con el fichero de configuración de la aplicación
extraVolumeMounts: |
  - name: spring-app-config
    mountPath: /opt/deployments/config
    readOnly: true
extraVolumes: |
  - name: spring-app-config
    configMap:
      name: config
      items:
      - key: application.yml
        path: application.yml
```

Además los ficheros que están bajo la carpeta `chart/resources` se inyectan como un configmap dentro de kubernetes.

```yaml
# chart/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  labels:
    app: {{ template "name" . }}
    chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
    release: {{ .Release.Name }}
    heritage: {{ .Release.Service }}
data:
  {{- (.Files.Glob "resources/*").AsConfig | nindent 2 }} # Todos los ficheros bajo 'resources/' los inyecta aquí
```

### Dependencias de una chart

Otra de las características de Helm es que permite declarar dependencias de una aplicación y se encarga de desplegarlas (si no lo están ya) al realizar el despliegue de la misma. Bajo el fichero [chart/requirements.yaml](chart/requirements.yaml) están declaradas como dependencias una chart de redis y otra de mongodb.

```yaml
dependencies:
  - name: redis
    version: 6.4.3
    repository: https://kubernetes-charts.storage.googleapis.com/
    alias: redis
  - name: mongodb
    version: 5.16.0
    repository: https://kubernetes-charts.storage.googleapis.com/
    alias: mongodb
```

Por otro lado, en el caso de querer sobrescribir la configuración de alguna de estas dos charts, definiendo un `alias` para cada una se puede sobrescribir dentro del [chart/values.yaml](chart/values.yaml):

```yaml
# Override default values for redis and mongo charts
redis:
  cluster:
    enabled: false
  usePassword: true
  password: myRedisPass
  master:
    service:
      type: LoadBalancer
      port: 6379
mongodb:
  service:
    type: LoadBalancer
  mongodbRootPassword: myR00tSup3rPass
  mongodbUsername: mongouser
  mongodbPassword: myM0ng0Pass
  mongodbDatabase: my-database
  port: 27017
```

Para obtener más información consulte las secciones de [configuración de mongodb](https://github.com/helm/charts/tree/master/stable/mongodb#configuration) y [configuración de redis](https://github.com/helm/charts/tree/master/stable/redis#configuration).

### Despliegue de la chart

Para desplegar la chart con los valores por defecto, se ejecutan desde la línea de comandos:

```bash
~$ cd chart
~$ helm dependency update # descarga las charts de dependencias de requirements.yaml
~$ helm install --name mychart ./ # instala la chart y la renombra a 'mychart'
```

Esto instalará la chart de la aplicación spring boot y las charts de las dependencias de redis y mongodb con los valores por defecto definidos en [chart/values.yaml](chart/values.yaml).

En el caso de despliegue en producción se pasaría como argumento el fichero [chart/values-production.yaml](chart/values-production.yaml) que sobrescribe a los valores por defecto.

```bash
~$ cd chart
~$ helm dependency update
~$ helm install --name mychart -f values-production.yaml ./
```

Ejecute `helm list` para ver el listado de charts desplegadas.

```bash
~$ helm list
NAME   	REVISION	UPDATED                 	STATUS  	CHART               	APP VERSION	NAMESPACE
mychart	1       	Fri Apr  5 13:07:27 2019	DEPLOYED	springboot-app-0.1.0	           	default  
```

Con `kubectl get all` se puede ver el estado de los recursos instalados en el clúster.

```bash
~$ kubectl get all
NAME                                          READY   STATUS    RESTARTS   AGE
pod/mychart-mongodb-c5984988d-2jmjc           1/1     Running   0          55s
pod/mychart-redis-master-0                    1/1     Running   0          55s
pod/mychart-springboot-app-54858c9f98-zlzfr   1/1     Running   0          55s

NAME                             TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)           AGE
service/kubernetes               ClusterIP      10.96.0.1        <none>        443/TCP           10d
service/mychart-mongodb          LoadBalancer   10.103.142.242   <pending>     27017:31189/TCP   55s
service/mychart-redis-master     LoadBalancer   10.99.248.137    <pending>     6379:32022/TCP    55s
service/mychart-springboot-app   LoadBalancer   10.97.77.55      <pending>     8080:30592/TCP    55s

NAME                                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/mychart-mongodb          1/1     1            1           55s
deployment.apps/mychart-springboot-app   1/1     1            1           55s

NAME                                                DESIRED   CURRENT   READY   AGE
replicaset.apps/mychart-mongodb-c5984988d           1         1         1       55s
replicaset.apps/mychart-springboot-app-54858c9f98   1         1         1       55s

NAME                                    READY   AGE
statefulset.apps/mychart-redis-master   1/1     55s
```

## Consulta de servicios

En este punto se puede atacar a los endpoints del servicio para recuperar distinta información.

### Consulta de salud de redis y mongodb

Nos indica si el servicio ha establecido correctamente la conexión con redis y mongodb.

```bash
~$ curl -s http://IP_SERVICIO_SPRINGBOOT_APP:8080/actuator/health
```

La salida debe ser algo parecido a esto:

```json
{
  "status": "UP",
  "details": {
    "diskSpace": {
      "status": "UP",
      "details": {
        "total": 17293533184,
        "free": 10744348672,
        "threshold": 10485760
      }
    },
    "mongo": {
      "status": "UP",
      "details": {
        "version": "4.0.8"
      }
    },
    "redis": {
      "status": "UP",
      "details": {
        "version": "4.0.14"
      }
    }
  }
}
```

### Consulta de variables de entorno

Nos retorna las variables de entorno que el servicio dispone.

```bash
~$ curl -s http://IP_SERVICIO_SPRINGBOOT_APP:8080/actuator/env
```

En la salida encontraremos las variables `$REDIS_CONNECTION_URL` y `$MONGODB_CONNECTION_URL` con sus valores actuales:

```text
// ...

"MONGODB_CONNECTION_URL": {
  "value": "mongodb://mongouser:myM0ng0Pass@mychart-mongodb:27017/my-database",
  "origin": "System Environment Property \"MONGODB_CONNECTION_URL\""
},
"REDIS_CONNECTION_URL": {
  "value": "redis://:myRedisPass@mychart-redis-master:6379",
  "origin": "System Environment Property \"REDIS_CONNECTION_URL\""
}

// ...
```

### Consulta de configuración aplicada

Nos retorna la configuración aplicada en el servicio.

```bash
~$ curl -s http://IP_SERVICIO_SPRINGBOOT_APP:8080/actuator/configprops
```

En la salida encontraremos las propiedades de configuración de redis y mongodb y los valores que se han aplicado como configuración del servicio:

```text
// ...

"spring.data.mongodb-org.springframework.boot.autoconfigure.mongo.MongoProperties": {
  "prefix": "spring.data.mongodb",
  "properties": {
    "uri": "mongodb://mongouser:myM0ng0Pass@mychart-mongodb:27017/my-database"
  }
},

// ...

"spring.redis-org.springframework.boot.autoconfigure.data.redis.RedisProperties": {
  "prefix": "spring.redis",
  "properties": {
    "database": 0,
    "port": 6379,
    "jedis": {},
    "host": "localhost",
    "ssl": false,
    "lettuce": {
      "shutdownTimeout": {
        "units": [
          "SECONDS",
          "NANOS"
        ]
      }
    },
    "url": "redis://:myRedisPass@mychart-redis-master:6379"
  }
},

// ...
```

## Conclusión

Como se ha podido ver, Kubernetes junto con Helm, permite crear un artefacto que disponga todo la información necesaria para el despliegue de una aplicación. Este enfoque permitirá tener siempre alineado el artefacto desplegable, `docker image`, junto con la configuración de la propia aplicación y la configuracion de recursos de infraestructura necesaria.

## Referencias

https://helm.sh/docs/using_helm/#installing-helm \
https://helm.sh/docs/developing_charts/ \
https://helm.sh/docs/chart_best_practices/#the-chart-best-practices-guide \
https://github.com/helm/helm/tree/master/docs