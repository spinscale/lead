# lead - little elasticsearch alerting deployment

This is a small command line tool helping to manage watches via a versioning system
by managing templates.

**Note: This is a prototype for gathering feedback and not to be supposed a
full production-ready tool. Please open issues for further discussion. **

## Installation

First, make sure you have crystal 0.27.0 installed. See the [crystal install docs](https://crystal-lang.org/docs/installation/).

```
shards build lead --release
```

The resulting `lead` binary should be copied somewhere to the local `PATH` to
make it available.

## Configuration

In order to run `lead` you need a single directory consisting of a configuration
file and a `watches` directory. This repository contains a sample `config` directory.

### `lead.yml` configuration

```yaml
elasticsearch:
  host: localhost
  # all optional
  #port: 9200
  #user: my_user
  #pass: my_pass

watches:
  - watch:
    # id of the watch, must be unique
    id: "my_first_watch"
    # variables to be used in the template
    vars:
      username: "alex"

  - watch:
    id: "my_second_watch"
    vars:
      username: "stefan"
```

### Writing watch templates using crinja

The templating language used is [crinja](https://github.com/straight-shoota/crinja), a jinja2 like dialect, written in crystal.

```
{
  "trigger": {
    {% include "include_trigger.tmpl" %}
  },
  "input": {
    "simple": {
      "foo":"bar"
    }
  },
  "condition":{ "script" :
    {
      "source":"return ctx.payload.foo == 'bar'",
      "lang":"painless"
    }
  },
  "actions":{
    "logme":{
      "logging": {
        "level":"info",
        "text":"{{ '{{ctx}}' }}"
      }
    }
  }
}
```

As you can see above you can include other templates, whose name should not have a `.json` suffix, as this would confused as a regular watch

```
"schedule": {
  "interval":"3h"
}
```

If you want to use mustache within a watch, it means you have to escape it like this

```
"text" : "{{ '{{ctx.payload}}' }}"
```

or

```
"text" : "{% raw %}{{ctx.payload}}{% endraw %}",
```


## Usage

The only prerequisites you need is a directory that contains the `lead.yml` file
and a `templates` directory, which contains the watch templates.

You can either always use the `-c path/to/config/directory` parameter for each of
the actions or set `export LEAD_CONFIG=/path/to/config/directory` in your environment
and then this will be used by default.


### `lead verify`

The `verify` command is a local only call, which

* checks for duplicate watch ids in your configuration
* checks if all referred templates exists
* compiles all templates to their final JSON
* ensures the JSON is valid


### `lead deploy`

The `deploy` command rolls out the changes to the cluster and updates all
the watches that require updating, by comparing their JSON.

When running without the `-f` no changes on the cluster will be executed, only the
required changes will be shown.

If you are changing an included template, all watches using this template will
be updated, as all their JSON will have changed.

This command will call the `verify` command first.


### `lead delete`

This command compares the watches from the repository with those stored in the
cluster and delete those that are not stored locally.

If you really want to delete the watches, you need to provide the `--force`
parameter.

**NOTE** This can lead to data loss, if you have manually added watches to your
cluster or if the monitoring watches are running.



### `lead dump watch_id`

Allows you compile a watch and inspect the JSON of a compiled template.



## Missing features

* Tests need to be added, resulting in a full rewrite instead of putting everything in a single file
* injecting passwords/auth stuff (pgpass style?) from somewhere else
* TLS support in the HTTP client
* Allow `lead delete` to ignore monitoring watches/have a custom list
* post deployment notifications (slack, webpush, email)
* The watch fields need to be defined in the template like the `GET Watch API` actually returns them. For example this means you need to specify the scripting language instead of the `"script": "return ctx.payload.hits.total > 0"`


## Development

Most likely you found a bug in this pretty raw tool.
In that case please write a failing test in `spec/`, fix it and open a pull request.
Alternatively open an issue with a sample snippet of JSON and I'll take a look
at it when possible.

You can run the tests locally by running `crystal spec`.


## Contributing

1. Fork it (<https://github.com/your-github-user/lead/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [spinscale](https://github.com/spinscale) Alexander Reelsen - creator, maintainer
