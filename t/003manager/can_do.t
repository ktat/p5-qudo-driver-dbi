use Qudo::Test;
use Mock::Qudo::Driver::DBI;
use Test::More;
use Test::Output;

run_tests(1, sub {
    my $driver = shift;
    my $master = test_master(
        driver_class => $driver,
    );

    my $manager = $master->manager;
    $manager->enqueue("Worker::Test",  { arg => 'arg',  uniqkey => 'uniqkey'});
    $manager->enqueue("Worker::Test2", { arg => 'oops', uniqkey => 'uniqkey'});
    is $manager->work_once, undef;

    teardown_dbs;
});

package Worker::Test;
use base 'Qudo::Worker';

sub work {
    my ($class, $job) = @_;
    print STDOUT $job->arg;
    $job->completed;
}

package Worker::Test2;
use base 'Qudo::Worker';

sub work {
    my ($class, $job) = @_;
    print STDOUT $job->arg;
    $job->completed;
}

