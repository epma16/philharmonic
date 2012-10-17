'''
Created on Oct 9, 2012

@author: kermit
'''

import time
from Queue import Queue, Empty
import logging
from datetime import datetime, timedelta 

import conf
from benchmark import Benchmark
from energy_price import EnergyPrice
import philharmonic.openstack.console_api as openstack

def log(message):
    print(message)
    logging.info(message)

class PeakPauser(object):
    def __init__(self):
        self.paused=False
        openstack.dummy = conf.dummy
        openstack.authenticate()
        

    def parse_prices(self, location, percentage_to_pause):
        self.energy_price = EnergyPrice(location, percentage_to_pause)
    
    def price_is_expensive(self):
        return self.energy_price.is_expensive()
    
    def commence_benchmark(self, command, scripted):
        self.q = Queue()  # this is where we'll get the messages from
        benchmark = Benchmark(command, scripted)
        benchmark.q = self.q
        benchmark.start()
        print("started benchmark")
    
    def benchmark_done(self):
        try:
            self.results = self.q.get_nowait()
            return True  # benchmark done, we got the results 
        except Empty:  # benchmark still executing
            return False
        
    def pause(self):
        if not self.paused:
            if not conf.dummy:
                openstack.pause(conf.instance)
            self.paused = True
            print("paused")
    
    def unpause(self):
        if self.paused:
            if not conf.dummy:
                openstack.unpause(conf.instance)
            print("unpaused")
            self.paused = False
    
    def initialize(self):
        self.unpause()  # in case the VM was paused before we started
        self.parse_prices(conf.historical_en_prices_file, conf.percentage_to_pause)
        self.start = datetime.now()
        log("#scheduler#start %s" % str(self.start))
        self.commence_benchmark(conf.command, scripted = not conf.dummy)  # go!!!
    
    def finalize(self):
        self.end = datetime.now()
        log("#scheduler#end %s" % str(self.end))
        self.duration = self.start - self.end
        log("#scheduler#runtime %s" % str(self.duration))
        
    def run(self):
        self.initialize()
        while True:
            if self.benchmark_done():
                print("benchmark done")
                break
            if self.price_is_expensive():
                self.pause()
            else:
                self.unpause()
            time.sleep(conf.sleep_interval)
        self.finalize()

if __name__=="__main__":
    scheduler = PeakPauser()
    scheduler.run()
