Maint Uploader
==============

This Ruby script is designed to parse the IEEE 802.1 Maintenance email reflector archive and find new maintenance request forms.
It then parses and uploads these to the [802.1 Maintenance Database](https://github.com/jlm/maint) web application.  The maintenance
database is a Ruby on Rails web app which exposes a JSON API as well as a web-based user interface.

The email archive is managed using Listserv which generates an index on HTML pages.  The excellent XML and HTML parser,
Nokogiri, can parse these without difficulty.

Configuration
-------------
The URLs of the maintenance databse API and the Listserv message archive, together with the usernames and passwords for each,
are stored in `secrets.yml` which is not included in the sources.  An example of that file file is available as `example-secrets.yml`.

Deployment
----------

The script can be deployed in a Docker container.  I use a very simple one based on Ruby:2.3.0-onbuild.  This method is frowned upon.
Bear in mind that the `secrets.yml` file will be included into the container, so the container is secret too.  There are methods
to isolate the secret information from the container, but I have not bothered to do this.

License
-------
Copyright 2016-2017 John Messenger

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Author
------
John Messenger, ADVA Optical Networking Ltd., Vice-chair, 802.1
