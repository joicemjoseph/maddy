maddy-smtp(5) "maddy mail server" "maddy reference documentation"

; TITLE SMTP endpoint module

# SMTP endpoint module (smtp)

Module 'smtp' is a listener that implements ESMTP protocol with optional
authentication, LMTP and Submission support. Incoming messages are processed in
accordance with pipeline rules (explained in Message pipeline section below).

```
smtp tcp://0.0.0.0:25 {
    hostname example.org
    tls /etc/ssl/private/cert.pem /etc/ssl/private/pkey.key
    io_debug no
    debug no
    insecure_auth no
    read_timeout 10m
    write_timeout 1m
    max_message_size 32M
    auth pam
    defer_sender_reject yes
    dmarc yes
	limits {
		endpoint rate 10
		endpoint concurrency 500
	}

    # Example pipeline ocnfiguration.
    destination example.org {
        deliver_to &local_mailboxes
    }
    default_destination {
        reject
    }
}
```

## Configuration directives

*Syntax*: hostname _string_ ++
*Default*: global directive value

Server name to use in SMTP banner.

```
220 example.org ESMTP Service Ready
```

*Syntax*: tls _certificate_path_ _key_path_ { ... } ++
*Default*: global directive value

TLS certificate & key to use. Fine-tuning of other TLS properties is possible
by specifing a configuration block and options inside it:
```
tls cert.crt key.key {
    protocols tls1.2 tls1.3
}
```
See section 'TLS configuration' in *maddy*(1) for valid options.

*Syntax*: io_debug _boolean_ ++
*Default*: no

Write all commands and responses to stderr.

*Syntax*: debug _boolean_ ++
*Default*: global directive value

Enable verbose logging.

*Syntax*: insecure_auth _boolean_ ++
*Default*: no (yes if TLS is disabled)

Allow plain-text authentication over unencrypted connections. Not recommended!

*Syntax*: read_timeout _duration_ ++
*Default*: 10m

I/O read timeout.

*Syntax*: write_timeout _duration_ ++
*Default*: 1m

I/O write timeout.

*Syntax*: max_message_size _size_ ++
*Default*: 32M

Limit the size of incoming messages to 'size'.

*Syntax*: auth _module_reference_ ++
*Default*: not specified

Use the specified module for authentication.

*Syntax*: defer_sender_reject _boolean_ ++
*Default*: yes

Apply sender-based checks and routing logic when first RCPT TO command
is received. This allows maddy to log recipient address of the rejected
message and also improves interoperability with (improperly implemented)
clients that don't expect an error early in session.

*Syntax*: max_logged_rcpt_errors _integer_ ++
*Default*: 5

Amount of RCPT-time errors that should be logged. Further errors will be
handled silently. This is to prevent log flooding during email dictonary
attacks (address probing).

*Syntax*: max_received _integer_ ++
*Default*: 50

Max. amount of Received header fields in the message header. If the incoming
message has more fields than this number, it will be rejected with the permanent error
5.4.6 ("Routing loop detected").

*Syntax*: ++
	buffer ram ++
	buffer fs _[path]_ ++
	buffer auto _max_size_ _[path]_ ++
*Default*: auto 1M StateDirectory/buffer

Temporary storage to use for the body of accepted messages.

- ram

Store the body in RAM.

- fs

Write out the message to the FS and read it back as needed.
_path_ can be omitted and defaults to StateDirectory/buffer.

- auto

Store message bodies smaller than _max_size_ entirely in RAM, otherwise write
them out to the FS.
_path_ can be omitted and defaults to StateDirectory/buffer.

*Syntax*: dmarc _boolean_ ++
*Default*: yes

Enforce sender's DMARC policy. Due to implementation limitations, it is not a
check module.

*NOTE*: Report generation is not implemented now.

*NOTE*: DMARC needs SPF and DKIM checks to function correctly.
Without these, DMARC check will not run.

## Rate & concurrency limiting

*Syntax*: limits _config block_ ++
*Default*: no limits

This allows configuring a set of message flow restrictions including
max. concurrency and rate per-endpoint, per-source, per-destination.

Limits are specified as directives inside the block:
```
limits {
	all rate 20
	destination concurrency 5
}
```

Supported limits:

- Rate limit

*Syntax*: _scope_ rate _burst_ _[period]_ ++
Restrict the amount of messages processed in _period_ to _burst_ messages.
If period is not specified, 1 second is used.

- Concurrency limit

*Syntax*: _scope_ concurrency _max_ ++
Restrict the amount of messages processed in parallel to _max_.

For each supported limitation, _scope_ determines whether it should be applied
for all messages ("all"), per-sender IP ("ip"), per-sender domain ("source") or
per-recipient domain ("destination"). Having a scope other than "all" means
that the restriction will be enforced independently for each group determined
by scope. E.g.  "ip rate 20" means that the same IP cannot send more than 20
messages in a scond. "destination concurrency 5" means that no more than 5
messages can be sent in parallel to a single domain.

*Note*: At the moment, SMTP endpoint on its own does not support per-recipient
limits.  They will be no-op. If you want to enforce a per-recipient restriction
on outbound messages, do so using 'limits' directive for the 'remote' module
(see *maddy-targets*(5)).

It is possible to share limit counters between multiple endpoints (or any other
modules). To do so define a top-level configuration block for module "limits"
and reference it where needed using standard & syntax. E.g.
```
limits inbound_limits {
	all rate 20
}

smtp smtp://0.0.0.0:25 {
	limits &inbound_limits
	...
}

submission tls://0.0.0.0:465 {
	limits &inbound_limits
	...
}
```
Using an "all rate" restriction in such way means that no more than 20
messages can enter the server through both endpoints in one second.

# Submission module (submission)

Module 'submission' implements all functionality of the 'smtp' module and adds
certain message preprocessing on top of it, additionaly authentication is
always required.

'submission' module checks whether addresses in header fields From, Sender, To,
Cc, Bcc, Reply-To are correct and adds Message-ID and Date if it is missing.

```
submission tcp://0.0.0.0:587 tls://0.0.0.0:465 {
    # ... same as smtp ...
}
```

# LMTP module (lmtp)

Module 'lmtp' implements all functionality of the 'smtp' module but uses
LMTP (RFC 2033) protocol.

```
lmtp unix://lmtp.sock {
    # ... same as smtp ...
}
```

## Limitations of LMTP implementation

- Can't be used with TCP.

- Per-recipient status is not supported.

- Delivery to 'sql' module storage is always atomic, either all recipients will
  succeed or none of them will.

# Mesage pipeline

Message pipeline is a set of module references and associated rules that
describe how to handle messages.

The pipeline is responsible for
- Running message filters (called "checks"), (e.g. DKIM signature verification,
  DNSBL lookup and so on).

- Running message modifiers (e.g. DKIM signature creation).

- Assocating each message recipient with one or more delivery targets.
  Delivery target is a module that does final processing (delivery) of the
  message.

Message handling flow is as follows:
- Execute checks referenced in top-level 'check' blocks (if any)

- Execute modifiers referenced in top-level 'modify' blocks (if any)

- If there are 'source' blocks - select one that matches message sender (as
  specified in MAIL FROM). If there are no 'source' blocks - entire
  configuration is assumed to be the 'default_source' block.

- Execute checks referenced in 'check' blocks inside selected 'source' block
  (if any).

- Execute modifiers referenced in 'modify' blocks inside selected 'source'
  block (if any).

Then, for each recipient:
- Select 'destination' block that matches it. If there are
  no 'destination' blocks - entire used 'source' block is interpreted as if it
  was a 'default_destination' block.

- Execute checks referenced in 'check' block inside selected 'destination' block
  (if any).

- Execute modifiers referenced in 'modify' block inside selected 'destination'
  block (if any).

- If used block contains 'reject' directive - reject the recipient with
  specified SMTP status code.

- If used block contains 'deliver_to' directive - pass the message to the
  specified target module. Only recipients that are handled
  by used block are visible to the target.

Each recipient is handled only by a single 'destination' block, in case of
overlapping 'destination' - first one takes priority.
```
destination example.org {
    deliver_to targetA
}
destination example.org { # ambiguous and thus not allowed
    deliver_to targetB
}
```
Same goes for 'source' blocks, each message is handled only by a single block.

Each recipient block should contain at least one 'deliver_to' directive or
'reject' directive. If 'destination' blocks are used, then
'default_destination' block should also be used to specify behavior for
unmatched recipients.  Same goes for source blocks, 'default_source' should be
used if 'source' is used.

That is, pipeline configuration should explicitly specify behavior for each
possible sender/recipient combination.

Additionally, directives that specify final handling decision ('deliver_to',
'reject') can't be used at the same level as source/destination rules.
Consider example:
```
destination example.org {
    deliver_to local_mboxes
}
reject
```
It is not obvious whether 'reject' applies to all recipients or
just for non-example.org ones, hence this is not allowed.

Complete configuration example using all of the mentioned directives:
```
check {
    # Run a check to make sure source SMTP server identification
    # is legit.
    require_matching_ehlo
}

# Messages coming from senders at example.org will be handled in
# accordance with the following configuration block.
source example.org {
    # We are example.com, so deliver all messages with recipients
    # at example.com to our local mailboxes.
    destination example.com {
        deliver_to &local_mailboxes
    }

    # We don't do anything with recipients at different domains
    # because we are not an open relay, thus we reject them.
    default_destination {
        reject 521 5.0.0 "User not local"
    }
}

# We do our business only with example.org, so reject all
# other senders.
default_source {
    reject
}
```

## Directives

*Syntax*: check _block name_ { ... } ++
*Context*: pipeline configuration, source block, destination block

List of the module references for checks that should be executed on
messages handled by block where 'check' is placed in.

Note that message body checks placed in destination block are currently
ignored. Due to the way SMTP protocol is defined, they would cause message to
be rejected for all recipients which is not what you usually want when using
such configurations.

Example:
```
check {
    # Reference implicitly defined default configuration for check.
    require_matching_ehlo

    # Inline definition of custom config.
    require_source_mx {
         # Configuration for require_source_mx goes here.
         fail_action reject
    }
}
```

It is also possible to define the block of checks at the top level
as "checks" module and reference it using & syntax. Example:
```
checks inbound_checks {
	require_matching_ehlo
}

# ... somewhere else ...
{
	...
	check &inbound_checks
}
```

*Syntax*: modify { ... } ++
*Default*: not specified ++
*Context*: pipeline configuration, source block, destination block

List of the module references for modifiers that should be executed on
messages handled by block where 'modify' is placed in.

Message modifiers are similar to checks with the difference in that checks
purpose is to verify whether the message is legitimate and valid per local
policy, while modifier purpose is to post-process message and its metadata
before final delivery.

For example, modifier can replace recipient address to make message delivered
to the different mailbox or it can cryptographically sign outgoing message
(e.g. using DKIM). Some modifier can perform multiple unrelated modifications
on the message.

*Note*: Modifiers that affect source address can be used only globally or on
per-source basis, they will be no-op inside destination blocks. Modifiers that
affect the message header will affect it for all recipients.

It is also possible to define the block of modifiers at the top level
as "modiifers" module and reference it using & syntax. Example:
```
modifiers local_modifiers {
	replace_rcpt file /etc/maddy/aliases
}

# ... somewhere else ...
{
	...
	modify &local_modifiers
}
```

*Syntax*: ++
    reject _smtp_code_ _smtp_enhanced_code_ _error_description_ ++
    reject _smtp_code_ _smtp_enhanced_code_ ++
    reject _smtp_code_ ++
    reject ++
*Context*: destination block

Messages handled by the configuration block with this directive will be
rejected with the specified SMTP error.

If you aren't sure which codes to use, use 541 and 5.4.0 with your message or
just leave all arguments out, the error description will say "message is
rejected due to policy reasons" which is usually what you want to mean.

'reject' can't be used in the same block with 'deliver_to' or
'destination/source' directives.

Example:
```
reject 541 5.4.0 "We don't like example.org, go away"
```

*Syntax*: deliver_to _target-config-block_ ++
*Context*: pipeline configuration, source block, destination block

Deliver the message to the referenced delivery target. What happens next is
defined solely by used target. If deliver_to is used inside 'destination'
block, only matching recipients will be passed to the target.

*Syntax*: source_in _table reference_ { ... } ++
*Context*: pipeline configuration

Handle messages with envelope senders present in the specified table in
accordance with the specified configuration block.

Takes precedence over all 'sender' directives.

Example:
```
source_in file /etc/maddy/banned_addrs {
	reject 550 5.7.0 "You are not welcome here"
}
source example.org {
	...
}
...
```

See 'destination_in' documentation for note about table configuration.

*Syntax*: source _rules..._ { ... } ++
*Context*: pipeline configuration

Handle messages with MAIL FROM value (sender address) matching any of the rules
in accordance with the specified configuration block.

"Rule" is either a domain or a complete address. In case of overlapping
'rules', first one takes priority. Matching is case-insensitive.

Example:
```
# All messages coming from example.org domain will be delivered
# to local_mailboxes.
source example.org {
    deliver_to &local_mailboxes
}
# Messages coming from different domains will be rejected.
default_source {
    reject 521 5.0.0 "You were not invited"
}
```

*Syntax*: reroute { ... } ++
*Context*: pipeline configuration, source block, destination block

This directive allows to make message routing decisions based on the
result of modifiers. The block can contain all pipeline directives and they
will be handled the same with the exception that source and destination rules
will use the final recipient and sender values (e.g. after all modifiers are
applied).

Here is the concrete example how it can be useful:
```
destination example.org {
    modify {
        replace_rcpt file /etc/maddy/aliases
    }
    reroute {
        destination example.org {
            deliver_to &local_mailboxes
        }
        default_destination {
            deliver_to &remote_queue
        }
    }
}
```

This configuration allows to specify alias local addresses to remote ones
without being an open relay, since remote_queue can be used only if remote
address was introduced as a result of rewrite of local address.

*WARNING*: If you have DMARC enabled (default), results generated by SPF
and DKIM checks inside a reroute block *will not* be considered in DMARC
evaluation.

*Syntax*: destination_in _table reference_ { ... } ++
*Context*: pipeline configuration, source block

Handle messages with envelope recipients present in the specified table in
accordance with the specified configuration block.

Takes precedence over all 'destination' directives.

Example:
```
destination_in file /etc/maddy/remote_addrs {
	deliver_to smtp tcp://10.0.0.7:25
}
destination example.com {
	deliver_to &local_mailboxes
}
...
```

Note that due to the syntax restrictions, it is not possible to specify
extended configuration for table module. E.g. this is not valid:
```
destination_in sql_table {
	dsn ...
	driver ...
} {
	deliver_to whatever
}
```

In this case, configuration should be specified separately and be referneced
using '&' syntax:
```
table.sql_table remote_addrs {
	dsn ...
	driver ...
}

whatever {
	destination_in &remote_addrs {
		deliver_to whatever
	}
}
```

*Syntax*: destination _rule..._ { ... } ++
*Context*: pipeline configuration, source block

Handle messages with RCPT TO value (recipient address) matching any of the
rules in accordance with the specified configuration block.

"Rule" is either a domain or a complete address. Duplicate rules are not
allowed. Matching is case-insensitive.

Note that messages with multiple recipients are split into multiple messages if
they have recipients matched by multiple blocks. Each block will see the
message only with recipients matched by its rules.

Example:
```
# Messages with recipients at example.com domain will be
# delivered to local_mailboxes target.
destination example.com {
    deliver_to &local_mailboxes
}

# Messages with other recipients will be rejected.
default_destination {
    rejected 541 5.0.0 "User not local"
}
```

## Reusable pipeline parts (msgpipeline module)

The message pipeline can be used independently of the SMTP module in other
contexts that require a delivery target.

Full pipeline functionality can be used where a delivery target is expected.
