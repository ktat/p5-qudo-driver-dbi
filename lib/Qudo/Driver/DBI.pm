package Qudo::Driver::DBI;

use strict;
use warnings;
use DBI;
use Carp qw/croak/;

use Qudo::Driver::DBI::DBD;

sub init_driver {
    my ($class, $master) = @_;

    for my $database (@{$master->{databases}}) {
        my $connection = bless {
            database => $database,
            dbh      => '',
            dbd      => '',
        }, $class;
        $connection->_connect();

        my $dbd_type = $connection->{dbh}->{Driver}->{Name};
        $connection->{dbd} = Qudo::Driver::DBI::DBD->new($dbd_type);

        $master->set_connection($database->{dsn}, $connection);
    }
}

sub _connect {
    my $self = shift;
    
    $self->{dbh} = DBI->connect(
        $self->{database}->{dsn},
        $self->{database}->{username},
        $self->{database}->{password},
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, %{ $self->{database}->{connect_options} || {} } }
    );
}

sub job_status_list {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT
            job_status.id,
            job_status.func_id,
            job_status.arg,
            job_status.uniqkey,
            job_status.status,
            job_status.job_start_time,
            job_status.job_end_time
        FROM
            job_status
    };

    my @funcs;
    if( $args->{funcs} ){
        if( ref($args->{funcs}) eq 'ARRAY' ){
            @funcs = @{$args->{funcs}};
        }
        else{
            push @funcs , $args->{funcs};
        }

        $sql .= sprintf( q{
            INNER JOIN
                func
            ON
                job_status.func_id = func.id
            WHERE (func.name IN (%s) )}, join(',',map{'?'} @funcs) );
    }

    $sql .= q{ LIMIT ? OFFSET ? };

    my $sth = $self->_execute(
        $sql,
        [ @funcs , $args->{limit} ,$args->{offset} ]
    );

    my @job_status_list;
    while (my $row = $sth->fetchrow_hashref) {
        push @job_status_list, $row;
    }
    return \@job_status_list;
}

sub job_count {
    my ($self , $funcs) = @_;

    my $sql = q{
        SELECT
            COUNT(job.id) AS count
        FROM
            job, func
        WHERE
            job.func_id = func.id
    };
    if( $funcs ){
        $sql .= q{ AND }. $self->_join_func_name($funcs);
    }

    my $sth = $self->{dbh}->prepare( $sql );

    eval{
        $sth->execute( @{$funcs} );
    };
    if( my $e =  $@ ){
        croak 'job_count ERROR'.$e;
    }
    my $ret = $sth->fetchrow_hashref();
    return $ret->{count};
}

sub job_list {
    my ($self, $limit, $funcs) = @_;

    my $sql = $self->_search_job_sql();
    $sql .= q{
        WHERE
            job.grabbed_until <= ? 
          AND
            job.run_after <= ?
    };
    my @bind = $self->get_server_time;
    push @bind, $self->get_server_time;

    # func.name
    if( $funcs ){
        $sql .= q{ AND }. $self->_join_func_name($funcs);
        push @bind , @{$funcs};
    }

    # limit
    $sql .= q{LIMIT ?};
    push @bind , $limit;

    my $sth = $self->{dbh}->prepare( $sql );

    eval{
        $sth->execute( @bind );
    };
    if( my $e =  $@ ){
        croak 'job_list ERROR'.$e;
    }

    my $code = $self->_get_job_data( $sth );

    my @jobs;
    while (1) {
        my $row = $code->();
        last unless $row;
        push @jobs, $row;
    }
    return \@jobs;
}

sub exception_list {
    my ($self, $args) = @_;

    my @bind   = ();
    my $limit  = $args->{limit};
    my $offset = $args->{offset};
    my $funcs  = $args->{funcs} || '';
    my $sql = q{
        SELECT
            exception_log.id,
            exception_log.func_id,
            exception_log.exception_time,
            exception_log.message,
            exception_log.uniqkey,
            exception_log.arg,
            exception_log.retried
        FROM
            exception_log
    };

    # funcs
    if ($funcs) {
        $sql .= q{
            INNER JOIN
                func
            ON
                exception_log.func_id = func.id
            WHERE
        };
        $sql .= $self->_join_func_name($funcs);
        push @bind , @{$funcs};
    }

    # limit
    if( $limit ){
        $sql .= q{ LIMIT ? };
        push @bind , $limit;
    }

    #offset
    if( $offset ){
        $sql .= q{OFFSET ?};
        push @bind , $offset;
    }

    my $sth = $self->{dbh}->prepare( $sql );
    eval{
        $sth->execute( @bind );
    };
    if( my $e =  $@ ){
        croak 'exception_list ERROR'.$e;
    }
    my @exception_list;
    while (my $row = $sth->fetchrow_hashref) {
        push @exception_list, $row;
    }
    return \@exception_list;
}


sub lookup_job {
    my ($self, $job_id) = @_;

    my $sql = $self->_search_job_sql();

    my @bind;
    # func.name
    if( $job_id ){
        $sql .= q{ WHERE job.id = ?};
        push @bind , $job_id;
    }

    # limit
    $sql .= q{LIMIT 1};

    my $sth = $self->{dbh}->prepare( $sql );

    eval{
        $sth->execute( @bind );
    };
    if( my $e =  $@ ){
        croak 'lookup_job ERROR'.$e;
    }

    return $self->_get_job_data( $sth );
}

sub find_job {
    my ($self, $limit, $func_map) = @_;

    my $sql = $self->_search_job_sql();
    $sql .= q{
        WHERE
            job.grabbed_until <= ? 
        AND
            job.run_after <= ?
    };
    my @bind = $self->get_server_time;
    push @bind, $self->get_server_time;

    # func.name
    if( $func_map ){
        my $keys = [keys %$func_map];
        $sql .= q{ AND }. $self->_join_func_name($keys);
        push @bind , @{$keys};
    }

    # priority
    $sql .= q{ ORDER BY job.priority DESC };

    # limit
    $sql .= q{ LIMIT ? };
    push @bind , $limit;

    my $sth = $self->{dbh}->prepare( $sql );

    eval{
        $sth->execute( @bind );
    };
    if( my $e =  $@ ){
        croak 'find_job ERROR'.$e;
    }

    return $self->_get_job_data( $sth );
}

sub _search_job_sql {
    q{
        SELECT
            job.id AS id,
            job.arg AS arg,
            job.uniqkey AS uniqkey,
            job.func_id AS func_id,
            job.grabbed_until AS grabbed_until,
            job.retry_cnt AS retry_cnt,
            job.priority AS priority,
            func.name AS funcname
        FROM job
        INNER JOIN
            func ON job.func_id = func.id
    };
}

sub _get_job_data {
    my ($self, $sth) = @_;
    sub{
        while (my $row = $sth->fetchrow_hashref) {
            return +{
                job_id            => $row->{id},
                job_arg           => $row->{arg},
                job_uniqkey       => $row->{uniqkey},
                job_grabbed_until => $row->{grabbed_until},
                job_retry_cnt     => $row->{retry_cnt},
                job_priority      => $row->{priority},
                func_id           => $row->{func_id},
                func_name         => $row->{funcname},
            };
        }
        return;
    };
}

sub grab_a_job {
    my ($self, %args) = @_;

    my $sth = $self->{dbh}->prepare(
        q{
            UPDATE
                job
            SET
                grabbed_until = ?
            WHERE
                id = ?
            AND
                grabbed_until = ?
        }
    );

    my $rows;
    eval{
        $rows = $sth->execute(
            $args{grabbed_until},
            $args{job_id},
            $args{old_grabbed_until},
        );
    };
    if( my $e =  $@ ){
        croak 'grab_a_job ERROR'.$e;
        return;
    }

    return $rows;
}

sub logging_exception {
    my ($self, $args) = @_;

    my $sth = $self->{dbh}->prepare(
        q{
            INSERT INTO exception_log
                ( func_id , message , uniqkey, arg, exception_time, retried)
            VALUES
                ( ? , ? , ?, ?, ?, ?)
        }
    );

    eval{
        $sth->execute(
            $args->{func_id} , 
            $args->{message} , 
            $args->{uniqkey} , 
            $args->{arg} , 
            time(),
            0,
        );
    };
    if( my $e =  $@ ){
        croak 'logging_exception ERROR'.$e;
    }
    return;
}

sub set_job_status{
    my ($self, $args) = @_;

    my @column = keys %{$args};
    my $sql  = $self->_build_insert_sql(
        'job_status',
        \@column
    );

    my @bind = map {$args->{$_}} @column;

    $self->_execute(
        $sql,
        \@bind
    );

    return;
}

sub get_server_time {
    my $self = shift;

    my $unixtime_sql = $self->{dbd}->sql_for_unixtime;
    my $time;
    eval {
        $time = $self->{dbh}->selectrow_array("SELECT $unixtime_sql");
    };
    if ($@) { $time = time }
    return $time;
}

sub enqueue {
    my ($self, $args) = @_;

    $args->{enqueue_time}  ||= time;
    $args->{grabbed_until} ||= 0;
    $args->{retry_cnt}     ||= 0;
    $args->{run_after}     = time + ($args->{run_after}||0);
    $args->{priority}      ||= 0;

    my @column = keys %{$args};
    my $sql  = $self->_build_insert_sql(
        'job',
        \@column
    );

    my $sth_ins = $self->{dbh}->prepare( $sql );
    my @bind = map {$args->{$_}} @column;
    eval{
        $sth_ins->execute( @bind );
    };
    if( $@ ){
        croak 'enqueue ERROR'.$@;
    }

    my $id = $self->{dbd}->last_insert_id($self->{dbh}, $sth_ins);
    my $sth_sel = $self->{dbh}->prepare(
        q{SELECT * FROM job WHERE id = ?}
    );

    $sth_sel->execute( $id );
    my $ret_sel = $sth_sel->fetchrow_hashref();
    return $ret_sel ? $ret_sel->{id} : undef;
}

sub reenqueue {
    my ($self, $job_id, $args) = @_;

    my $sth = $self->{dbh}->prepare(
        q{
            UPDATE
                job
            SET
                enqueue_time  = ?,
                run_after     = ?,
                retry_cnt     = ?,
                grabbed_until = ?
            WHERE
                id = ?
        }
    );

    my $row;
    eval{
        $row = $sth->execute(
            time,
            (time + ($args->{retry_delay}||0) ),
            $args->{retry_cnt},
            $args->{grabbed_until},
            $job_id,
        );
    };
    if( my $e =  $@ ){
        croak 'reenqueue ERROR'.$e;
        return;
    }

    return $row;
}


sub dequeue {
    my ($self, $args) = @_;
    my $sth = $self->{dbh}->prepare(
        q{DELETE FROM  job WHERE id = ?}
    );

    my $row;
    eval{
        $row = $sth->execute( $args->{id} );
    };
    if( my $e = $@ ){
        croak 'dequeue ERROR'.$e;
    }

    return $row;
}


sub get_func_id {
    my ($self, $funcname) = @_;
    
    my $sth_sel = $self->{dbh}->prepare(
        q{SELECT * FROM func WHERE name = ?}
    );

    $sth_sel->execute( $funcname );
    my $func_id;
    my $ret_hashref = $sth_sel->fetchrow_hashref();
    if ( $ret_hashref ){
        $func_id =  $ret_hashref->{id};
    }
    else{
        my $sth_ins = $self->{dbh}->prepare(
            q{INSERT INTO func ( name ) VALUES ( ? )}
        );
        eval{
            $sth_ins->execute( $funcname );
        };
        if( my $e = $@ ){
            croak $e;
        }
        $sth_sel->execute( $funcname );
        my $ret_hashref = $sth_sel->fetchrow_hashref();
        if ( $ret_hashref ){
            $func_id =  $ret_hashref->{id};
        }
    }

    return $func_id;
}

sub get_func_name {
    my ($self, $funcid) = @_;

    my $sth;
    eval {
        $sth = $self->{dbh}->prepare(
            q{SELECT * FROM func WHERE id = ?}
        );
        $sth->execute( $funcid );
    };
    if ($@) { croak $@ }

    my $ret_hashref = $sth->fetchrow_hashref();
    return $ret_hashref ? $ret_hashref->{name} : undef;
}

sub retry_from_exception_log {
    my ($self, $exception_log_id) = @_;

    $self->_execute(
        q{UPDATE exception_log SET retried = 1 WHERE id = ?},
        [$exception_log_id]
    );
}

sub _execute {
    my ($self, $sql, $bind) = @_;

    my $sth;
    eval {
        $sth = $self->{dbh}->prepare($sql);
        $sth->execute(@{$bind});
    };
    if ($@) { croak $@ }
    $sth;
}

sub _join_func_name{
    my ($self , $funcs ) = @_;

    my $func_name = sprintf(
        q{ func.name IN (%s) } ,
        join(',', map { '?' } @{$funcs} )
    );

    return $func_name;
}

sub _build_insert_sql{
    my( $self , $table , $column_ary_ref ) = @_;

    my $sql  = qq{ INSERT INTO $table ( };
       $sql .= join ' , ' , @{$column_ary_ref};
       $sql .= ' ) VALUES ( ';
       $sql .= join( ' , ', ('?') x @{$column_ary_ref} );
       $sql .= ' )';

    return $sql;
}

1;


