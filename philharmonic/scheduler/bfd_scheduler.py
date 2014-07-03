from philharmonic.scheduler.ischeduler import IScheduler
from philharmonic import Schedule, Migration

def sort_vms_decreasing(VMs):
    return sorted(VMs, key=lambda x : (x.res['#CPUs'], x.res['RAM']),
                  reverse=True)

def sort_pms_increasing(PMs, state):
    return sorted(PMs,
                  key=lambda x : (state.free_cap[x]['#CPUs'],
                                  state.free_cap[x]['RAM']))

class BFDScheduler(IScheduler):
    """Best fit decreasing (BFD) scheduler, as proposed for
    [OpenStack Neat](http://openstack-neat.org/).

    """

    def __init__(self, cloud=None, driver=None):
        IScheduler.__init__(self, cloud, driver)

    def _fits(self, vm, server):
        """Returns the utilisation of adding vm to server
        or -1 in case some resource's capacity is exceeded.

        """
        #TODO: this method should probably be a part of Cloud
        current = self.cloud._current
        total_utilisation = 0.
        utilisations = {}
        for i in server.resource_types:
            used = 0.
            for existing_vm in current.alloc[server]:
                used += existing_vm.res[i]
            # add our own VM's resource demand
            used += vm.res[i]
            utilisations[i] = used/server.cap[i]
            if used > server.cap[i]: # capacity exceeded for this resource
                return -1
        uniform_weight = 1./len(server.resource_types)
        weights = {res : uniform_weight for res in server.resource_types}
        for resource_type, utilisation in utilisations.iteritems():
            total_utilisation += weights[resource_type] * utilisation
        return total_utilisation

    def reevaluate(self):
        self.schedule = Schedule()
        t = self.environment.get_time()

        VMs = []
        # get VMs that need to be placed
        #  - VMs from boot requests
        requests = self.environment.get_requests()
        for request in requests:
            if request.what == 'boot':
                VMs.append(request.vm)
        #  - select VMs on underutilised PMs
        #  TODO

        # sort VMs decreasing

        # if len(requests) > 0:
        #    import ipdb; ipdb.set_trace()
        for request in requests:
            if request.what == 'boot':
                for server in self.cloud.servers:
                    utilisation = self._fits(request.vm, server)
                    #TODO: compare utilisations of different potential hosts
                    if utilisation != -1:
                        #import ipdb; ipdb.set_trace()
                        action = Migration(request.vm, server)
                        self.cloud.apply(action)
                        self.schedule.add(action, t)
                        break
        # for each boot request:
        # find the best server
        #  - find server that can host this VM
        #  - make sure the server's resources are now reserved
        # add new migration to the schedule
        return self.schedule
