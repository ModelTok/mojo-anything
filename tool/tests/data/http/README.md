# srv

The server tool/tests/test_app_http.mojo records. Its curl lines are the
recording's examples; the last four are not requests to this server.

```console
$ curl http://localhost:8080/hello
$ curl -X POST -d 'hello world' http://localhost:8080/upper
$ curl -sS http://127.0.0.1:8080/div/7/2
$ curl http://localhost:8080/div/1/0
$ curl http://localhost:8080/now
$ curl -H 'X-Name: Bob' -A agent/1.0 -b 'a=1' -e http://x/ --json '{"k":"v"}' http://[::1]:8080/echo
$ curl --data-binary @data/body.txt http://localhost:8080/echo
$ curl -d @data/body.txt http://localhost:8080/echo?x=1
$ curl -XPUT -HX-Mode:put 'http://localhost:8080/echo'
$ curl http://localhost:8080/bin
$ curl http://localhost:8080/chunked
$ curl -s -o /dev/null http://localhost:8080/headers
$ curl 'http://localhost:8080/search?q=a%20b&n=5#frag'
$ curl https://example.com/skip
$ curl http://localhost:8080/hello | jq .
$ curl --unknown x http://localhost:8080/
$ curl ftp://localhost/file
```
