## 0.1.0

- First release: `SethuClient`, collections, filters, ordering, cursor paging
  and `iterate()` over every matching record.
- Typed errors (`SethuApiError`), automatic retries and a request timeout.
- Refuses plain `http://` addresses unless `allowInsecureHttp` is set.
