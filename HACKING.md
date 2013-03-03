What can I do?
==============

Please have a look at the list of [known limitations and todos](https://github.com/jerico-dev/meteor-versioning#known-limitations--todos).


Where should I start?
=====================

There are three main classes you'll have to understand to get started. The 'TransactionsManager' class, the replacement for Meteor's 'Collection' class and the '_CrdtDocument' class.

I propose you start with the TransactionsManager class as it provides the general workflow of the package. Have a look at the public methods commit(), undo() and redo() and work your way backwards.

To fully understand what's happening in the TransactionsManager class you should familiarize yourself with two basic concepts that are being used a lot here:
 1. The [command pattern](https://en.wikipedia.org/wiki/Command_pattern)
 2. The concept of [vector clocks](https://en.wikipedia.org/wiki/Vector_clock) and especially what it means for an event to formally "happen-before" another event. We use this relationship to order transactions and establish causality between them.

If you understand the command pattern you'll see that the TransactionManager class acts as the invoker while the Meteor Collection replacement acts as the receiver of commands. Commands themselves are simple JavaScript objects without behavior.

So you next step should be to familiarize yourself with the Collection replacement. It contains receiver methods for all available operations. Now is the time, to understand a few basic [operational transformation](https://en.wikipedia.org/wiki/Operational_transformation) concepts, too, especially what it means to formalize operations and what the inverse of an operation does.

Once you got so far the remaining challenge is to understand the concept of a [Commutative Replicative Data Type](http://hal.inria.fr/docs/00/44/59/75/PDF/icdcs09-treedoc.pdf) (CRDT). If you've never heard about Operational Transformation or what it does, this will be the hardest challenge.

Fortunately we only implement the easier parts of the CRDT concept so far. You'll not have to understand much about a treedoc really, just get the basic idea of a CRDT. It's important to understand that the CRDT idea really means to attach a globally unique IDs to every change of a versioned object and track those IDs across all participating systems (clients and server). IDs must not only be universal but also their order must be the same across all participating nodes even when these nodes do not communicate directly or work concurrently.

Feel free to contact me (jerico.dev@gmail.com) if you need assistance in understanding these concepts.


How can I help?
===============

Every pull request is welcome. It can be to improve documentation, fix bugs, add features or remove some known limitation.

If you do not know how the fork, hack, commit, pull-request cycle works, let me know.


Can I ask questions?
====================

Of course! There are no silly questions and I'll answer all of them (if I can). Please contact me by email (jerico.dev@gmail.com).


I'm not a programmer but I need some feature really urgently.
=============================================================

If you're very lucky then what you need interests me personally and I'll do it for free. If you're lucky you have a budget. You can contract me as a freelancer and I'll implement exactly the feature you need. If you have a very small budget you can donate and I'll see what I can do. Please contact me beforehand if you want to be sure that your donation will be used the way you intend it.

Contact: jerico.dev@gmail.com

<a href='http://www.pledgie.com/campaigns/19414'>
  <img alt='Click here to support Meteor versioning and make a donation at www.pledgie.com!'
    src='http://www.pledgie.com/campaigns/19414.png?skin_name=chrome' border='0' />
</a>

