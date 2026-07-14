# Documenation around workers and controller nodes

## Converting a worker to a controller
I originally set up a single controller and two worker nodes. Wanted to update the controller to have etcd quarum

So talosctl reset doesn't seem to be a good idea, it wound up completely nuking the talos boot partition and I needed to reinstall it.
Will need to see how to reimage or return certain nodes into maintainance mode.


