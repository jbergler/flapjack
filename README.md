Flapjack
========

Flapjack is highly scalable and distributed monitoring system.

It understands the Nagios plugin format, and can easily be scaled
from 1 server to 1000.

Flapjack's current focus is on providing a scalable method for dealing with events representing changes in system state (OK -> WARNING -> CRITICAL transitions) and alerting appropriate people as necessary.

Developing
----------

Clone the repository:

    git clone https://auxesis@github.com/auxesis/flapjack.git

Install development dependencies:

    gem install bundler
    bundle install

Run the tests:

    cucumber features/

What things do
--------------

  * `flapjack-worker` => executes checks, reports results
  * `flapjack-worker-manager` => starts/stops a cluster of `flapjack-worker`
  * `flapjack-executive` => gets results, works out when and who to notify, sets downtime etc
  * `flapjack-stats` => gets stats from beanstalkd tubes (useful for benchmarks + performance analysis)
  * `flapjack-benchmark` => benchmarks various persistence/transport backend combinations


Testing
-------

Tests live in `features/`.

To run tests:

    $ rake cucumber


Architecture
------------

    -------------------        -------------------
    | web interface / |        | visualisation / |
    | dsl / flat file |        | reporting       |
    -------------------        -------------------
              |                   |
               \                 /
                \               /
                 ---------------
                 | persistence |
                 ---------------
                        |
          -------------------------------
          |                             |
          |                             |
          |                             |
    -------------                  ------------
    | populator |---          -----| notifier |
    -------------  |          |    ------------
                   |          |
                  --------------
                  | beanstalkd |
                  --------------
                        |
       -----------------------------------
       |                |                |
    ----------      ----------       ----------
    | worker |      | worker |       | worker |
    ----------      ----------       ----------


- populator determines checks that need to occur, and puts checks onto `jobs` tube
  - populator fetches jobs from a database
  - populator can be swapped out to get checks from a dsl or flat files
- workers pop a check off the beanstalk, perform check, put result onto `results` tube,
  re-add check to `jobs` tube with a delay.
- notifier pops results off `results` tube, notifies as necessary

Releasing
---------

Gem releases are handled with [Jeweler](https://github.com/technicalpickles/jeweler).

Event-Processing
================

Here's some notes on the event-processing branch, which is at "development of a working prototype".

Dependencies
------------

Apart from gems:
- Redis

Starting Resque Workers
-----------------------

We're using [Resque](https://github.com/defunkt/resque) to queue notifications generated by flapjack-executive. The queues are named as follows:
- email_notifications
- sms_notifications

There'll be more of these as we add more notification mediums. One resque worker that processes both queues (but prioritises SMS above email) can be started as follows:

    QUEUE=sms_notifications,email_notifications VERBOSE=1 be rake resque:work

resque sets the command name so grep'ing ps output for `rake` or `ruby` will NOT find resque processes. Search instead for `resque`. (and remember the 'q').

To background it you can add `BACKGROUND=yes`. Excellent documentation is available in (Resque's README)[https://github.com/defunkt/resque/blob/master/README.markdown]


