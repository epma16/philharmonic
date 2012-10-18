'''
Created on Oct 9, 2012

@author: kermit
'''

# I/O
#======

#historical_en_prices = "./io/energy_price_data-quick_test.csv"
historical_en_prices = "./io/energy_price_data-test.csv"

results = "./io/results.pickle"

# Benchmark
#===========

# if dummy == True, will do just a local dummy benchmark, faking all the OpenStack commands
dummy = False
# for False set all these other settings...

# host on which the benchmark VM is deployed (for energy measurements)
host = "snowwhite"

# VM (instance) which executes the benchmark  
instance = "kermit-test"

# the command to execute as a benchmark (use ssh to execute something in a VM)
#command = "/usr/bin/ssh 192.168.100.4 ls"
command = "./io/benchmark.sh"

# how many % of hours in a day should the VM be paused
percentage_to_pause = 0.04 # *100%
#percentage_to_pause = 0.15 # *100%

# time to sleep between checking if the benchmark finished or needs to be paused
sleep_interval = 1 # seconds
