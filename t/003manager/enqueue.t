use Qudo::Test;
use Mock::Qudo::Driver::DBI;
use Test::More;

run_tests(3, sub {
    my $driver = shift;
    my $master = test_master(
        driver_class => $driver,
    );

    my $manager = $master->manager;
    $manager->can_do('Worker::Test');
    my $job = $manager->enqueue("Worker::Test", { arg => 'arg', uniqkey => 'uniqkey'});

    is $job->id, 1;
    is $job->arg, 'arg';
    is $job->uniqkey, 'uniqkey';

    teardown_dbs;
});

package Worker::Test;
use base 'Qudo::Worker';
